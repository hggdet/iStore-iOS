import Foundation

// MARK: - Persisted repository record

/// A user-added app source (AltStore-style). Only the URL + a display name are
/// persisted; the fetched catalog is kept in memory and re-fetched on demand.
struct Repository: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let url: URL
    var name: String
    let addedAt: Date

    init(id: UUID = UUID(), url: URL, name: String, addedAt: Date = .now) {
        self.id = id
        self.url = url
        self.name = name
        self.addedAt = addedAt
    }
}

// MARK: - AltStore source JSON (lenient)

/// A decoded AltStore/SideStore source. Decoding is deliberately forgiving: one
/// malformed app entry is skipped rather than failing the whole feed, and every
/// non-essential field is optional — this is untrusted data off the network.
struct RepoSource: Codable, Equatable, Sendable {
    let name: String?
    let identifier: String?
    let iconURL: URL?
    let apps: [RepoApp]

    private enum CodingKeys: String, CodingKey { case name, identifier, iconURL, apps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        identifier = try? c.decodeIfPresent(String.self, forKey: .identifier)
        iconURL = LenientDecode.url(c, .iconURL)
        // Skip individual bad entries instead of nuking the entire list.
        let raw = (try? c.decode([FailableApp].self, forKey: .apps)) ?? []
        apps = raw.compactMap(\.value)
    }

    /// Wrapper so a single un-decodable app doesn't fail the whole array.
    private struct FailableApp: Decodable {
        let value: RepoApp?
        init(from decoder: Decoder) throws { value = try? RepoApp(from: decoder) }
    }
}

/// A published version in a source catalog. Keeping the complete version list
/// lets the UI explain update history while the existing download path still
/// uses the same first-version fields as before.
struct RepoVersion: Codable, Equatable, Identifiable, Sendable {
    let version: String?
    let downloadURL: URL?
    let size: Int64?

    var id: String {
        "\(version ?? "")|\(downloadURL?.absoluteString ?? "")"
    }

    init(version: String?, downloadURL: URL?, size: Int64?) {
        self.version = version
        self.downloadURL = downloadURL
        self.size = size
    }

    private enum CodingKeys: String, CodingKey { case version, downloadURL, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        downloadURL = LenientDecode.url(c, .downloadURL)
        size = LenientDecode.int64(c, .size)
    }
}

/// One app in a source. Handles both the flat v1 shape (`version`,
/// `downloadURL`, `size` at the top level) and the newer v2 shape where those
/// live in a `versions` array — the first version still drives downloads.
struct RepoApp: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let bundleIdentifier: String
    let developerName: String?
    let localizedDescription: String?
    let category: String?
    let iconURL: URL?
    let urlSchemes: [String]
    let screenshotURLs: [URL]
    let version: String?
    let downloadURL: URL?
    let size: Int64?
    let versions: [RepoVersion]

    var id: String { bundleIdentifier.isEmpty ? name : bundleIdentifier }

    private enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, localizedDescription, category
        case iconURL, urlSchemes, urlScheme, screenshotURLs, screenshots, version, downloadURL, size, versions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled"
        bundleIdentifier = (try? c.decodeIfPresent(String.self, forKey: .bundleIdentifier)) ?? ""
        developerName = try? c.decodeIfPresent(String.self, forKey: .developerName)
        localizedDescription = try? c.decodeIfPresent(String.self, forKey: .localizedDescription)
        category = try? c.decodeIfPresent(String.self, forKey: .category)
        iconURL = LenientDecode.url(c, .iconURL)
        var decodedSchemes = (try? c.decodeIfPresent([String].self, forKey: .urlSchemes)) ?? []
        if let singleScheme = try? c.decode(String.self, forKey: .urlScheme) {
            decodedSchemes.append(singleScheme)
        }
        urlSchemes = decodedSchemes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, scheme in
                if !result.contains(scheme) { result.append(scheme) }
            }

        let primaryScreenshots = (try? c.decodeIfPresent([String].self, forKey: .screenshotURLs)) ?? []
        let fallbackScreenshots = (try? c.decodeIfPresent([String].self, forKey: .screenshots)) ?? []
        screenshotURLs = (primaryScreenshots + fallbackScreenshots).compactMap(URL.init(string:))

        let flatVersion = try? c.decodeIfPresent(String.self, forKey: .version)
        let flatURL = LenientDecode.url(c, .downloadURL)
        let flatSize = LenientDecode.int64(c, .size)
        let decodedVersions = (try? c.decodeIfPresent([RepoVersion].self, forKey: .versions)) ?? []
        var uniqueVersions: [RepoVersion] = []
        var seenVersionIDs = Set<String>()
        for candidate in decodedVersions where seenVersionIDs.insert(candidate.id).inserted {
            uniqueVersions.append(candidate)
        }
        let first = uniqueVersions.first
        versions = uniqueVersions.isEmpty && (flatVersion != nil || flatURL != nil || flatSize != nil)
            ? [RepoVersion(version: flatVersion, downloadURL: flatURL, size: flatSize)]
            : uniqueVersions
        version = flatVersion ?? first?.version
        downloadURL = flatURL ?? first?.downloadURL
        size = flatSize ?? first?.size
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try c.encodeIfPresent(developerName, forKey: .developerName)
        try c.encodeIfPresent(localizedDescription, forKey: .localizedDescription)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(iconURL?.absoluteString, forKey: .iconURL)
        try c.encode(urlSchemes, forKey: .urlSchemes)
        try c.encode(screenshotURLs.map(\.absoluteString), forKey: .screenshotURLs)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeIfPresent(downloadURL?.absoluteString, forKey: .downloadURL)
        try c.encodeIfPresent(size, forKey: .size)
        try c.encode(versions, forKey: .versions)
    }
}

/// URLs and numbers in real-world feeds are inconsistent (bad URL strings,
/// sizes as strings). Decode them without throwing so one odd value can't sink
/// the whole parse.
private enum LenientDecode {
    static func url<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> URL? {
        guard let s = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
        return URL(string: s)
    }
    static func int64<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int64? {
        if let n = try? c.decodeIfPresent(Int64.self, forKey: key) { return n }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        return nil
    }
}

// MARK: - Store

/// Remembers added repositories on-device (Application Support), fetches their
/// AltStore JSON catalogs, and downloads an app's IPA into the container. A
/// completed download is surfaced via `pendingIPA` for the silent installer to adopt.
@MainActor
final class RepositoryStore: ObservableObject {
    @Published private(set) var repositories: [Repository] = []

    /// Last successfully fetched catalog per repository (in memory only).
    @Published var catalog: [UUID: RepoSource] = [:]
    @Published var fetchError: [UUID: String] = [:]
    @Published var loadingRepoID: UUID?
    @Published private(set) var catalogCacheLoaded = false

    /// Bundle id of the app currently downloading, if any.
    @Published var activeDownloadID: String?
    /// Remains active from GET through signing and the iOS install handoff.
    @Published var activeInstallID: String?
    @Published var downloadError: String?
    @Published var installError: String?
    /// Source apps that have reached the iOS installer. The UI verifies this
    /// state when Open is tapped and clears it if iOS cannot open the app.
    @Published private(set) var installedAppIDs: Set<String>
    @Published private(set) var installedVersions: [String: String]
    @Published var pendingAppID: String?
    @Published var pendingAppName: String?
    /// True only when the user explicitly requested a separately signed copy.
    @Published var pendingInstallAsAdditionalCopy = false

    /// Set when a download finishes — the silent installer observes this and loads it.
    @Published var pendingIPA: URL?

    private let indexURL: URL
    private let cacheURL: URL
    private let downloadsDir: URL
    private var installWatchdogTask: Task<Void, Never>?

    private struct Index: Codable { var repositories: [Repository] = [] }
    private let repositoriesDefaultsKey = "istore.repositories.index"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        indexURL = base.appendingPathComponent("repositories.json")
        cacheURL = base.appendingPathComponent("repository-catalog-cache.json")
        downloadsDir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        installedAppIDs = Set(UserDefaults.standard.stringArray(forKey: "istore.installed-app-ids") ?? [])
        installedVersions = UserDefaults.standard.dictionary(forKey: "istore.installed-app-versions") as? [String: String] ?? [:]
        load()
        seedDefaultRepositories()
        Task { @MainActor [weak self] in
            await self?.loadCatalogCache()
        }
        #if DEBUG
        RepoSource._selfTest()
        #endif
    }

    // MARK: Default sources

    private func seedDefaultRepositories() {
        let defaults: [(String, String)] = [
            ("https://repository.apptesters.org", "AppTesters"),
            ("https://raw.githubusercontent.com/AbdTench/SwiftSource/refs/heads/main/My%20Source", "Cinemana"),
            ("https://bit.ly/quantumsource-min", "Quantum Source"),
            ("https://appstore.sidelix.vip/repos/esign.php", "Sidelix App Store")
        ]
        let migrationKey = "sources.two-only.migrated"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            repositories.removeAll()
            for (rawURL, name) in defaults {
                if let url = URL(string: rawURL) {
                    repositories.append(Repository(url: url, name: name))
                }
            }
            UserDefaults.standard.set(true, forKey: migrationKey)
            save()
            return
        }
        var changed = false
        let sourceCountBeforeCleanup = repositories.count
        repositories.removeAll { repo in
            repo.name == "FastSign" ||
            repo.name == "Alan's Gigantic Repo" ||
            repo.url.absoluteString == "https://fastsign.dev/repo.json"
        }
        changed = repositories.count != sourceCountBeforeCleanup
        for (rawURL, name) in defaults {
            guard let url = URL(string: rawURL),
                  !repositories.contains(where: { $0.url == url }) else { continue }
            repositories.append(Repository(url: url, name: name))
            changed = true
        }
        if changed { save() }
    }

    // MARK: Repo list

    enum AddError: LocalizedError {
        case invalidURL, duplicate
        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a valid http(s) repository URL."
            case .duplicate: return "That repository is already added."
            }
        }
    }

    @discardableResult
    func add(urlString: String) -> Result<Repository, AddError> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return .failure(.invalidURL)
        }
        guard !repositories.contains(where: { $0.url == url }) else {
            return .failure(.duplicate)
        }
        let repo = Repository(url: url, name: url.host ?? trimmed)
        repositories.append(repo)
        save()
        return .success(repo)
    }

    func remove(_ repo: Repository) {
        repositories.removeAll { $0.id == repo.id }
        catalog[repo.id] = nil
        fetchError[repo.id] = nil
        save()
    }

    // MARK: Networking

    func refresh(_ repo: Repository) async {
        loadingRepoID = repo.id
        fetchError[repo.id] = nil
        defer { if loadingRepoID == repo.id { loadingRepoID = nil } }
        do {
            var req = URLRequest(url: repo.url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 120
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                fetchError[repo.id] = "The repository server returned an error."
                return
            }
            let source = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode(RepoSource.self, from: data)
            }.value
            catalog[repo.id] = source
            saveCatalogCache()
            // Adopt the source's own display name once we know it.
            if let name = source.name, !name.isEmpty,
               let i = repositories.firstIndex(where: { $0.id == repo.id }),
               repositories[i].name != name {
                repositories[i].name = name
                save()
            }
        } catch {
            fetchError[repo.id] = error.localizedDescription
        }
    }

    func beginInstallAttempt(_ appID: String) {
        installWatchdogTask?.cancel()
        activeInstallID = appID
        installError = nil
        installWatchdogTask = Task { @MainActor [weak self] in
            do {
                // No attempt should permanently disable every GET button after
                // a broken download, signing run, or iOS handoff.
                try await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            } catch {
                return
            }
            guard let self, self.activeInstallID == appID else { return }
            self.installError = "The installation timed out. Please try again."
            self.activeInstallID = nil
            self.activeDownloadID = nil
            self.pendingIPA = nil
            self.pendingAppID = nil
            self.pendingAppName = nil
            self.pendingInstallAsAdditionalCopy = false
            self.installWatchdogTask = nil
        }
    }

    func completeInstallAttempt(_ appID: String?, error: String? = nil) {
        if let error, !error.isEmpty {
            installError = error
        }
        if activeInstallID == appID {
            activeInstallID = nil
            activeDownloadID = nil
            pendingIPA = nil
            pendingAppID = nil
            pendingAppName = nil
            pendingInstallAsAdditionalCopy = false
            installWatchdogTask?.cancel()
            installWatchdogTask = nil
        }
    }

    func cancelInstallAttempt(_ appID: String) {
        guard activeInstallID == appID else { return }
        activeInstallID = nil
        activeDownloadID = nil
        pendingAppID = nil
        pendingAppName = nil
        pendingInstallAsAdditionalCopy = false
        pendingIPA = nil
        installError = nil
        installWatchdogTask?.cancel()
        installWatchdogTask = nil
    }

    /// Removes only IPAs downloaded by the repository flow. Files selected by
    /// the user from another location are never touched.
    func removeDownloadedIPA(_ url: URL) {
        let downloadsPath = downloadsDir.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(downloadsPath + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func markInstalled(_ appID: String, version: String? = nil) {
        installedAppIDs.insert(appID)
        if let version, !version.isEmpty {
            installedVersions[appID] = version
        }
        UserDefaults.standard.set(Array(installedAppIDs), forKey: "istore.installed-app-ids")
        UserDefaults.standard.set(installedVersions, forKey: "istore.installed-app-versions")
    }

    func clearInstalled(_ appID: String) {
        installedAppIDs.remove(appID)
        installedVersions.removeValue(forKey: appID)
        UserDefaults.standard.set(Array(installedAppIDs), forKey: "istore.installed-app-ids")
        UserDefaults.standard.set(installedVersions, forKey: "istore.installed-app-versions")
    }

    func isUpdateAvailable(for app: RepoApp) -> Bool {
        guard installedAppIDs.contains(app.id),
              let installed = installedVersions[app.id],
              let latest = app.version,
              !installed.isEmpty, !latest.isEmpty else { return false }
        return compareVersions(latest, installed) == .orderedDescending
    }

    private func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0.filter("0123456789".contains)) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0.filter("0123456789".contains)) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    func download(_ app: RepoApp, asAdditionalCopy: Bool = false) async {
        guard let url = app.downloadURL else {
            downloadError = "This app has no download URL."
            return
        }
        activeDownloadID = app.id
        beginInstallAttempt(app.id)
        pendingAppID = app.id
        pendingAppName = app.name
        pendingInstallAsAdditionalCopy = asAdditionalCopy
        downloadError = nil
        defer { if activeDownloadID == app.id { activeDownloadID = nil } }
        do {
            // Streams to a temp file — safe for large IPAs (no full in-memory load).
            var request = URLRequest(url: url)
            request.timeoutInterval = 300
            let (tempURL, resp) = try await URLSession.shared.download(for: request)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                let message = "Download failed — the server returned an error."
                downloadError = message
                completeInstallAttempt(app.id, error: message)
                return
            }
            // Never reuse the previous path: iOS can still be reading the old
            // served IPA while the user retries after deleting the app. A unique
            // destination also guarantees pendingIPA emits a new value.
            let baseName = (Self.ipaName(for: app) as NSString).deletingPathExtension
            let destination = downloadsDir.appendingPathComponent(
                "\(baseName)-\(UUID().uuidString).ipa"
            )
            // A cross-volume move can become a large copy. Keep it away from
            // the main actor so the app remains responsive when downloads end.
            try await Task.detached(priority: .utility) {
                let fileManager = FileManager.default
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: tempURL, to: destination)
            }.value
            pendingIPA = destination
        } catch {
            let message = error.localizedDescription
            downloadError = message
            completeInstallAttempt(app.id, error: message)
        }
    }

    /// A safe on-disk filename like `AppName-1.2.3.ipa`.
    private static func ipaName(for app: RepoApp) -> String {
        let base = app.name.isEmpty ? app.id : app.name
        let stem = base.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        let version = app.version.map { "-\($0)" } ?? ""
        return "\(stem)\(version).ipa"
    }

    // MARK: Persistence

    private func loadCatalogCache() async {
        let sourceURL = cacheURL
        let cached: [UUID: RepoSource]? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: sourceURL) else { return nil }
            return try? JSONDecoder().decode([UUID: RepoSource].self, from: data)
        }.value
        if let cached {
            for repo in repositories {
                if let source = cached[repo.id] {
                    catalog[repo.id] = source
                }
            }
        }
        catalogCacheLoaded = true
    }

    private func saveCatalogCache() {
        let snapshot = catalog
        let destination = cacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func load() {
        let fileData = try? Data(contentsOf: indexURL)
        let backupData = UserDefaults.standard.data(forKey: repositoriesDefaultsKey)
        if let data = fileData, let index = try? JSONDecoder().decode(Index.self, from: data) {
            repositories = index.repositories
        } else if let backupData,
                  let index = try? JSONDecoder().decode(Index.self, from: backupData) {
            repositories = index.repositories
        }
    }

    private func save() {
        let index = Index(repositories: repositories)
        if let data = try? JSONEncoder().encode(index) {
            // Keep a small preferences backup as well as the Application Support
            // file. This prevents user-added sources disappearing when iOS delays
            // or rejects a protected-file write during app backgrounding/refresh.
            UserDefaults.standard.set(data, forKey: repositoriesDefaultsKey)
            try? data.write(to: indexURL, options: [.atomic])
        }
    }
}

#if DEBUG
extension RepoSource {
    /// Smallest check that fails if the lenient decoder breaks — decodes both the
    /// flat (v1) and versioned (v2) AltStore shapes. Called once at debug launch.
    static func _selfTest() {
        guard let flat = """
        {"name":"Flat","apps":[{"name":"A","bundleIdentifier":"com.a",
        "version":"1.0","downloadURL":"https://e.com/a.ipa","size":123}]}
        """.data(using: .utf8),
        let versioned = """
        {"name":"V2","apps":[{"name":"B","bundleIdentifier":"com.b","versions":[
        {"version":"2.0","downloadURL":"https://e.com/b.ipa","size":"456"}]}]}
        """.data(using: .utf8),
        let f = try? JSONDecoder().decode(RepoSource.self, from: flat),
        let v = try? JSONDecoder().decode(RepoSource.self, from: versioned)
        else { return }
        assert(f.apps.first?.downloadURL?.absoluteString == "https://e.com/a.ipa")
        assert(f.apps.first?.size == 123)
        assert(f.apps.first?.versions.count == 1)
        assert(v.apps.first?.version == "2.0")
        assert(v.apps.first?.downloadURL?.absoluteString == "https://e.com/b.ipa")
        assert(v.apps.first?.size == 456)
        assert(v.apps.first?.versions.count == 1)
    }
}
#endif
