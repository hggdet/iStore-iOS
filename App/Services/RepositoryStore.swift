import Foundation

// MARK: - Persisted repository record

/// An app source (AltStore-style catalog). iStore is locked to a single,
/// fixed Ceresify repository — see `RepositoryStore.ceresifyRepository`.
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

    init(name: String?, identifier: String?, iconURL: URL?, apps: [RepoApp]) {
        self.name = name
        self.identifier = identifier
        self.iconURL = iconURL
        self.apps = apps
    }

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
    let date: Date?

    var id: String {
        "\(version ?? "")|\(downloadURL?.absoluteString ?? "")"
    }

    init(version: String?, downloadURL: URL?, size: Int64?, date: Date? = nil) {
        self.version = version
        self.downloadURL = downloadURL
        self.size = size
        self.date = date
    }

    private enum CodingKeys: String, CodingKey { case version, downloadURL, size, date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        downloadURL = LenientDecode.url(c, .downloadURL)
        size = LenientDecode.int64(c, .size)
        date = LenientDecode.date(c, .date)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(version, forKey: .version)
        try c.encodeIfPresent(downloadURL?.absoluteString, forKey: .downloadURL)
        try c.encodeIfPresent(size, forKey: .size)
        // Encoded as epoch seconds (not JSONEncoder's default reference-date
        // seconds) so it round-trips through `LenientDecode.date` unchanged.
        try c.encodeIfPresent(date?.timeIntervalSince1970, forKey: .date)
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
    /// When this app's current version was published. Falls back to the
    /// first entry in `versions` when the feed omits the flat field.
    let lastUpdated: Date?

    /// Row identity. Deliberately *not* the bundle id on its own: a single
    /// bundle id legitimately carries several different builds in this
    /// catalog — `com.google.ios.youtube` ships as iQTube, YouTube LRD,
    /// YouTube Sy, YouTube Plus, SAT YouTube and YouTube DLTube, and
    /// `com.zhiliaoapp.musically` as seven separate TikTok mods. Keying rows
    /// on the bundle id alone made every one of those variants share a single
    /// identity, so tapping GET on one spun the loading state on all of them
    /// and disabled the rest. Folding the name in gives each build its own
    /// identity while two listings of the genuinely same build still collapse.
    var id: String {
        let base = bundleIdentifier.isEmpty ? name : bundleIdentifier
        return name.isEmpty ? base : "\(base)|\(name)"
    }

    private enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, developerName, localizedDescription, category
        case iconURL, urlSchemes, urlScheme, screenshotURLs, screenshots, version, downloadURL, size, versions, versionDate
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
        let flatDate = LenientDecode.date(c, .versionDate)
        lastUpdated = flatDate ?? first?.date
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
        try c.encodeIfPresent(lastUpdated?.timeIntervalSince1970, forKey: .versionDate)
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

    // Only ever touched from the single background task that decodes a feed,
    // never concurrently — safe despite ISO8601DateFormatter not being Sendable.
    nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    /// Accepts either an ISO 8601 string from the network feed (with or
    /// without fractional seconds) or a `timeIntervalSince1970` number, which
    /// is how this app's own on-disk catalog cache round-trips dates.
    static func date<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) {
            return isoWithFraction.date(from: s) ?? isoPlain.date(from: s)
        }
        if let n = try? c.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: n)
        }
        return nil
    }
}

// MARK: - Category (admin panel controlled)

/// One browsable category exactly as Ceresify's admin panel defines it.
///
/// `originalName` is the key `/api/apps/paged?category=` filters on and must
/// be sent back verbatim — including any emoji prefix, and including the
/// `custom:<id>` form the panel uses for hand-built categories. `displayName`
/// is what the panel wants the user to read, which is often the same name
/// with the emoji stripped or replaced entirely. Showing `originalName` was
/// what made a renamed category keep its old label in the app.
struct RepoCategory: Codable, Equatable, Hashable, Identifiable, Sendable {
    let originalName: String
    let displayName: String
    let iconURL: URL?

    var id: String { originalName }

    private enum CodingKeys: String, CodingKey { case originalName, displayName, iconURL }

    init(originalName: String, displayName: String, iconURL: URL?) {
        self.originalName = originalName
        self.displayName = displayName
        self.iconURL = iconURL
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        originalName = try c.decode(String.self, forKey: .originalName)
        let decodedDisplay = try? c.decodeIfPresent(String.self, forKey: .displayName)
        if let name = decodedDisplay ?? nil, !name.isEmpty {
            displayName = name
        } else {
            displayName = originalName
        }
        iconURL = LenientDecode.url(c, .iconURL)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(originalName, forKey: .originalName)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(iconURL?.absoluteString, forKey: .iconURL)
    }
}

// MARK: - Promo banner (admin panel controlled)

/// One promotional banner from the panel's `Banner` collection. The API only
/// surfaces active ones, already ordered, on every page-1 response.
struct RepoBanner: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let imageURL: URL
    /// Where tapping the banner should go. Optional — a banner may be purely
    /// decorative, in which case it is shown but not tappable.
    let linkURL: URL?
}

// MARK: - Store

/// Fetches the Ceresify catalog (AltStore-shaped JSON) and downloads an app's
/// IPA into the container. A completed download is surfaced via `pendingIPA`
/// for the silent installer to adopt.
@MainActor
final class RepositoryStore: ObservableObject {
    @Published private(set) var repositories: [Repository] = []

    /// Last successfully fetched catalog per repository (in memory only).
    @Published var catalog: [UUID: RepoSource] = [:]
    @Published var fetchError: [UUID: String] = [:]
    @Published var loadingRepoID: UUID?

    /// The categories Ceresify's admin panel wants shown, in its own order.
    /// Populated as a side effect of `refresh(_:)` — every `/api/apps/paged`
    /// page-1 response carries the list, already filtered server-side (hidden
    /// categories are gone) and ranked by `CategoryOverride.order`.
    @Published private(set) var categories: [RepoCategory] = []

    /// Active promo banners, in the panel's order. Same page-1 side effect as
    /// `categories`, and cached so the strip is on screen at launch instead of
    /// popping in once the first refresh lands.
    @Published private(set) var banners: [RepoBanner] = []

    /// Bundle id of the app currently downloading, if any.
    @Published var activeDownloadID: String?
    /// Remains active from GET through signing and the iOS install handoff.
    @Published var activeInstallID: String?
    @Published var downloadError: String?
    @Published var installError: String?
    /// Source apps that have reached the iOS installer. The UI verifies this
    /// state when Open is tapped and clears it if iOS cannot open the app.
    @Published private(set) var installedAppIDs: Set<String>
    @Published var pendingAppID: String?
    @Published var pendingAppName: String?
    /// True only when the user explicitly requested a separately signed copy.
    @Published var pendingInstallAsAdditionalCopy = false

    /// Set when a download finishes — the silent installer observes this and loads it.
    @Published var pendingIPA: URL?

    private let indexURL: URL
    private let cacheURL: URL
    private let categoryCacheURL: URL
    private let bannerCacheURL: URL
    private let downloadsDir: URL
    private var installWatchdogTask: Task<Void, Never>?

    private struct Index: Codable { var repositories: [Repository] = [] }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        indexURL = base.appendingPathComponent("repositories.json")
        cacheURL = base.appendingPathComponent("repository-catalog-cache.json")
        // Deliberately the pre-existing filename: older builds wrote a bare
        // [String] here, and `loadCategoryCache` still migrates that shape.
        categoryCacheURL = base.appendingPathComponent("category-order-cache.json")
        bannerCacheURL = base.appendingPathComponent("banner-cache.json")
        downloadsDir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        installedAppIDs = Set(UserDefaults.standard.stringArray(forKey: "istore.installed-app-ids") ?? [])
        load()
        seedCeresifyRepository()
        Task { @MainActor [weak self] in
            await self?.loadCatalogCache()
            await self?.loadCategoryCache()
            await self?.loadBannerCache()
        }
        #if DEBUG
        RepoSource._selfTest()
        #endif
    }

    // MARK: Fixed source

    /// The single catalog iStore is locked to. Fixed id/date so the seed is a
    /// no-op (and the in-memory catalog cache still hits) once already saved.
    private static let ceresifyRepository = Repository(
        id: UUID(uuidString: "5B1D7C8A-1CE6-4A00-8000-000000000001")!,
        url: URL(string: "https://dev.ceresify.com/api/repo.json?ch=check0ver")!,
        name: "Ceresify",
        addedAt: Date(timeIntervalSince1970: 0)
    )

    private func seedCeresifyRepository() {
        guard repositories != [Self.ceresifyRepository] else { return }
        repositories = [Self.ceresifyRepository]
        catalog = [:]
        fetchError = [:]
        save()
    }

    // MARK: Networking
    //
    // `/api/repo.json` (the flat AltStore feed) turned out to silently omit a
    // handful of apps compared to the admin panel's real count, and carries no
    // per-app admin ordering. `/api/apps/paged` is the endpoint the panel
    // itself is built on: an empty `category` returns every active app sorted
    // newest-first, and a named category returns exactly that category's apps
    // in the admin's own configured order. Both fetches below page through it
    // (500/page, page 1 sequentially since it also carries the category
    // ranking, the rest concurrently).

    // Plain Sendable constants, but the enclosing type is @MainActor, which
    // isolates static members by default too — nonisolated so the paging
    // helpers below (also nonisolated, to run their network I/O concurrently)
    // can read them without hopping back to the main actor.
    private nonisolated static let pagedAppsBaseURL = "https://dev.ceresify.com/api/apps/paged"
    private nonisolated static let pagedAppsPageSize = 500
    /// Safety cap on pages fetched per request — comfortably above the whole
    /// catalog's current size (~10,400 apps ≈ 21 pages) without an unbounded loop.
    private nonisolated static let pagedAppsMaxPages = 40

    private struct PagedCatalogPage: Decodable {
        struct CategoryEntry: Decodable {
            let originalName: String?
            let displayName: String?
            let icon: String?
        }
        /// The panel calls these banners; the AltStore-shaped feed carries
        /// them under `news`, which is why the key does not match the name.
        struct NewsEntry: Decodable {
            let identifier: String?
            let imageURL: String?
            let url: String?
        }
        let apps: [RepoApp]
        let total: Int
        let categories: [CategoryEntry]?
        let news: [NewsEntry]?

        private enum CodingKeys: String, CodingKey { case apps, total, categories, news }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // `[RepoApp]` decoded straight would throw on the first entry the
            // decoder cannot read — failing the page, then all three retries,
            // then the whole refresh. One odd record would cost the entire
            // 10,400-app catalog, so entries are skipped individually here the
            // same way `RepoSource` already skips them in the flat feed.
            apps = (try c.decode([FailableApp].self, forKey: .apps)).compactMap(\.value)
            // `total` stays strict on purpose: it drives how many pages get
            // fetched, so defaulting a missing one to zero would silently cap
            // the catalog at a single page instead of failing into a retry.
            total = try c.decode(Int.self, forKey: .total)
            categories = try? c.decodeIfPresent([CategoryEntry].self, forKey: .categories)
            news = try? c.decodeIfPresent([NewsEntry].self, forKey: .news)
        }

        private struct FailableApp: Decodable {
            let value: RepoApp?
            init(from decoder: Decoder) throws { value = try? RepoApp(from: decoder) }
        }
    }

    /// A full catalog fetch fires this concurrently for every page (~21 requests
    /// for the current ~10,400-app catalog); with a plain single attempt, one
    /// flaky page on a real device's network — a timeout, a dropped connection —
    /// throws and, via `withThrowingTaskGroup`, discards every other page that
    /// already succeeded. Retrying transient failures here, per page, is what
    /// keeps one bad request from turning into "apps missing from the store".
    private nonisolated static func fetchPagedCatalogPage(category: String, page: Int) async throws -> PagedCatalogPage {
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            do {
                return try await fetchPagedCatalogPageOnce(category: category, page: page)
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 400_000_000 * UInt64(attempt + 1))
                }
            }
        }
        throw lastError
    }

    private nonisolated static func fetchPagedCatalogPageOnce(category: String, page: Int) async throws -> PagedCatalogPage {
        var comps = URLComponents(string: pagedAppsBaseURL)!
        var items = [
            URLQueryItem(name: "ch", value: "check0ver"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(pagedAppsPageSize))
        ]
        if !category.isEmpty {
            items.append(URLQueryItem(name: "category", value: category))
        }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 60
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try await Task.detached(priority: .utility) {
            try JSONDecoder().decode(PagedCatalogPage.self, from: data)
        }.value
    }

    /// What one catalog fetch yields, for `category` (`""` = the full "All"
    /// list, sorted newest-first). `categories` — the admin's own ranking —
    /// and `banners` ride along on the page-1 response regardless of the
    /// category filter, so they arrive for free with the apps.
    struct CatalogFetch: Sendable {
        let apps: [RepoApp]
        let categories: [RepoCategory]?
        let banners: [RepoBanner]?
    }

    /// Fetches every page and returns the whole list in one piece.
    private nonisolated static func fetchAllPagedApps(category: String) async throws -> CatalogFetch {
        let (first, remainingPages) = try await fetchFirstPagedApps(category: category)
        guard !remainingPages.isEmpty else { return first }
        let rest = await fetchRemainingPagedApps(category: category, pages: remainingPages)
        return CatalogFetch(apps: first.apps + rest, categories: first.categories, banners: first.banners)
    }

    /// Page 1, plus the range of further pages the response says exist.
    ///
    /// Split out from `fetchAllPagedApps` so a caller can put those first
    /// apps on screen immediately: the largest category runs to thirteen
    /// pages, and waiting for the slowest of them left the tab showing
    /// nothing at all for many seconds — even though the list only ever
    /// reveals twenty-five rows at a time.
    private nonisolated static func fetchFirstPagedApps(
        category: String
    ) async throws -> (fetch: CatalogFetch, remainingPages: Range<Int>) {
        let first = try await fetchPagedCatalogPage(category: category, page: 1)
        // `originalName` is the key the API filters on; `displayName` and
        // `icon` are what the panel wants shown for it. Entries without an
        // original name cannot be filtered on, so they are dropped.
        let categories = first.categories?.compactMap { entry -> RepoCategory? in
            guard let original = entry.originalName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !original.isEmpty else { return nil }
            let display = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return RepoCategory(
                originalName: original,
                displayName: display.flatMap { $0.isEmpty ? nil : $0 } ?? original,
                iconURL: entry.icon.flatMap(URL.init(string:))
            )
        }
        // A banner with no usable image is nothing to show, so it is dropped
        // rather than rendered as an empty slot in the strip.
        let banners = first.news?.compactMap { entry -> RepoBanner? in
            guard let raw = entry.imageURL, let image = URL(string: raw) else { return nil }
            return RepoBanner(
                id: entry.identifier ?? raw,
                imageURL: image,
                linkURL: entry.url.flatMap(URL.init(string:))
            )
        }

        let totalPages = first.total > 0
            ? min(Int((Double(first.total) / Double(pagedAppsPageSize)).rounded(.up)), pagedAppsMaxPages)
            : 1
        return (
            CatalogFetch(apps: first.apps, categories: categories, banners: banners),
            2 ..< (totalPages + 1)
        )
    }

    /// Pages 2…n, fetched concurrently and concatenated back in page order.
    ///
    /// A page that still fails after its three retries is skipped rather than
    /// thrown: these run as one task group, so rethrowing discarded every page
    /// that had already succeeded — one flaky request out of the thirteen the
    /// largest category needs would cost the whole tail of the list. Page 1 is
    /// the one that genuinely matters, and it is fetched separately above.
    private nonisolated static func fetchRemainingPagedApps(
        category: String,
        pages: Range<Int>
    ) async -> [RepoApp] {
        guard !pages.isEmpty else { return [] }
        let collected = await withTaskGroup(of: (Int, [RepoApp]).self) { group -> [Int: [RepoApp]] in
            for page in pages {
                group.addTask {
                    let result = try? await fetchPagedCatalogPage(category: category, page: page)
                    return (page, result?.apps ?? [])
                }
            }
            var collected: [Int: [RepoApp]] = [:]
            for await (page, pageApps) in group { collected[page] = pageApps }
            return collected
        }
        return pages.flatMap { collected[$0] ?? [] }
    }

    func refresh(_ repo: Repository) async {
        loadingRepoID = repo.id
        fetchError[repo.id] = nil
        defer { if loadingRepoID == repo.id { loadingRepoID = nil } }
        do {
            let fetched = try await Self.fetchAllPagedApps(category: "")
            catalog[repo.id] = RepoSource(name: repo.name, identifier: nil, iconURL: nil, apps: fetched.apps)
            saveCatalogCache()
            if let fetchedCategories = fetched.categories, !fetchedCategories.isEmpty {
                categories = fetchedCategories
                saveCategoryCache()
            }
            // Banners are replaced wholesale, empty included: pulling the last
            // active banner in the panel has to clear it from the app too.
            if let fetchedBanners = fetched.banners {
                banners = fetchedBanners
                saveBannerCache()
            }
            // Per-category lists are snapshots of the same panel data and are
            // stale once this lands, but they are NOT dropped here: wiping the
            // category the user is looking at emptied the screen for as long
            // as its re-fetch took — thirteen pages for the largest one — and
            // that happens on every foreground past the freshness window, not
            // just on an explicit pull. The Apps tab calls
            // `invalidateCategoryApps(keeping:)` instead, which drops the ones
            // nobody is looking at and re-reads the visible one in place.
        } catch {
            fetchError[repo.id] = error.localizedDescription
        }
    }

    /// Apps for one category, in the admin panel's own order — populated
    /// on demand when that category is actually browsed, kept in memory only.
    @Published private(set) var categoryApps: [String: [RepoApp]] = [:]
    @Published var categoryAppsError: [String: String] = [:]
    /// The fetch currently running for each category, so a second caller
    /// joins it instead of being turned away empty-handed.
    private var categoryTasks: [String: Task<Void, Never>] = [:]

    /// Drops every cached per-category list except `keeping`, so each one is
    /// re-read the next time it is opened. The kept category is the one on
    /// screen: the caller re-reads it in place via `refreshCategoryApps`, so
    /// its rows stay put instead of blanking out for the length of a fetch.
    func invalidateCategoryApps(keeping survivor: String?) {
        if let survivor, let kept = categoryApps[survivor] {
            categoryApps = [survivor: kept]
        } else {
            categoryApps.removeAll()
        }
        categoryAppsError.removeAll()
    }

    /// Loads `category` unless its list is already cached.
    func loadCategoryApps(_ category: String) async {
        guard categoryApps[category] == nil else { return }
        await fetchCategoryApps(category)
    }

    /// Re-reads `category` even if it is cached, replacing the list in place
    /// so the category on screen never blanks out mid-fetch.
    func refreshCategoryApps(_ category: String) async {
        await fetchCategoryApps(category)
    }

    /// The single fetch path for a category list.
    ///
    /// The network work runs in an unstructured `Task` on purpose. The Apps
    /// tab starts these from a SwiftUI `.task(id:)` that is cancelled the
    /// moment the user taps another chip, and a cancelled fetch used to leave
    /// the category with no list at all — while a concurrent caller that
    /// found it "already loading" returned instantly and rendered an empty
    /// list that only a pull-to-refresh could repair. Owning the task here
    /// means the fetch always runs to completion and fills the cache, and
    /// every caller awaits the same result.
    private func fetchCategoryApps(_ category: String) async {
        if let inFlight = categoryTasks[category] {
            await inFlight.value
            return
        }
        // Clear a previous failure up front: until this attempt settles the
        // tab should show its loading state, not the last error.
        categoryAppsError[category] = nil
        let task = Task { @MainActor [weak self] in
            defer { self?.categoryTasks[category] = nil }
            do {
                // Publish page 1 the moment it lands so the chip the user just
                // tapped fills in, then append the rest behind it. Only twenty
                // five rows are on screen anyway, and the tail of a thirteen
                // page category is thousands of rows further down.
                let (first, remainingPages) =
                    try await RepositoryStore.fetchFirstPagedApps(category: category)
                self?.categoryApps[category] = first.apps
                self?.categoryAppsError[category] = nil
                guard !remainingPages.isEmpty else { return }
                let rest = await RepositoryStore.fetchRemainingPagedApps(
                    category: category,
                    pages: remainingPages
                )
                self?.categoryApps[category] = first.apps + rest
            } catch {
                self?.categoryAppsError[category] = error.localizedDescription
            }
        }
        categoryTasks[category] = task
        await task.value
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

    func markInstalled(_ appID: String) {
        installedAppIDs.insert(appID)
        UserDefaults.standard.set(Array(installedAppIDs), forKey: "istore.installed-app-ids")
    }

    func clearInstalled(_ appID: String) {
        installedAppIDs.remove(appID)
        UserDefaults.standard.set(Array(installedAppIDs), forKey: "istore.installed-app-ids")
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
        guard let cached else { return }
        for repo in repositories {
            if let source = cached[repo.id] {
                catalog[repo.id] = source
            }
        }
    }

    private func saveCatalogCache() {
        let snapshot = catalog
        let destination = cacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func loadCategoryCache() async {
        let sourceURL = categoryCacheURL
        let cached: [RepoCategory]? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: sourceURL) else { return nil }
            if let decoded = try? JSONDecoder().decode([RepoCategory].self, from: data) {
                return decoded
            }
            // Builds before category display names existed cached a bare name
            // list here. Read it rather than discarding it — the next refresh
            // replaces it with the panel's real display names anyway.
            guard let names = try? JSONDecoder().decode([String].self, from: data) else { return nil }
            return names.map { RepoCategory(originalName: $0, displayName: $0, iconURL: nil) }
        }.value
        guard let cached, !cached.isEmpty else { return }
        categories = cached
    }

    private func loadBannerCache() async {
        let sourceURL = bannerCacheURL
        let cached: [RepoBanner]? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: sourceURL) else { return nil }
            return try? JSONDecoder().decode([RepoBanner].self, from: data)
        }.value
        guard let cached, !cached.isEmpty else { return }
        banners = cached
    }

    private func saveBannerCache() {
        let snapshot = banners
        let destination = bannerCacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func saveCategoryCache() {
        let snapshot = categories
        let destination = categoryCacheURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return }
        repositories = index.repositories
    }

    private func save() {
        let index = Index(repositories: repositories)
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .completeFileProtection)
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
