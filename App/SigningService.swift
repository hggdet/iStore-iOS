import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// Bridges the zsign C++ engine into Swift and manages file staging.
@MainActor
final class SigningService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case signing
        case done(String)
        case failed(String)
    }

    @Published var phase: Phase = .idle

    let tempDir: URL
    let workDir: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iStore", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        workDir = base
        tempDir = base.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    /// Brings a picked or downloaded file into the app container.
    ///
    /// `takeOwnership` must be true only when the caller owns the source file
    /// (e.g. the temporary file handed back by `URLSession.download`). In that
    /// case the file is moved, which is O(1) on the same volume instead of a
    /// full byte copy. Otherwise a hard link is attempted first and a copy is
    /// used as the fallback for cross-volume sources such as the Files
    /// provider.
    ///
    /// `nonisolated` because this can move hundreds of megabytes and must
    /// never run on the main actor.
    nonisolated func stage(_ url: URL, as name: String? = nil, takeOwnership: Bool = false) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = workDir.appendingPathComponent(name ?? url.lastPathComponent)
        let fm = FileManager.default
        try? fm.removeItem(at: dest)

        if takeOwnership {
            if (try? fm.moveItem(at: url, to: dest)) != nil { return dest }
        } else {
            // Same-volume hard link: no bytes are read or written.
            if (try? fm.linkItem(at: url, to: dest)) != nil { return dest }
        }

        do {
            try fm.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Runs the zsign signing engine. Blocking — call from a background task.
    /// Returns success, a message, the signed bundle identifier, and version.
    nonisolated static func sign(ipa: URL, p12: URL, password: String, profile: URL,
                     bundleId: String, displayName: String, shortVersion: String,
                     icon: URL?, output: URL, tempDir: URL,
                     removeExtensions: Bool, enableDocuments: Bool,
                     dylib: URL? = nil, injectIntoExtensions: Bool = false)
        -> (ok: Bool, message: String, signedBundleId: String, signedVersion: String) {
        #if !FORGE_BRIDGE
        // UI-preview builds (e.g. the simulator target) omit the zsign engine.
        return (false, "Signing engine unavailable in this build.", "", "1.0")
        #else
        var msgBuf = [CChar](repeating: 0, count: 1024)
        var bidBuf = [CChar](repeating: 0, count: 512)
        var verBuf = [CChar](repeating: 0, count: 128)
        let status = forgesign_sign_ipa(
            ipa.path, p12.path, password, profile.path,
            bundleId.isEmpty ? nil : bundleId,
            displayName.isEmpty ? nil : displayName,
            shortVersion.isEmpty ? nil : shortVersion,
            icon?.path,
            output.path,
            tempDir.path,
            removeExtensions ? 1 : 0,
            enableDocuments ? 1 : 0,
            dylib?.path,
            injectIntoExtensions ? 1 : 0,
            &msgBuf, Int32(msgBuf.count),
            &bidBuf, Int32(bidBuf.count),
            &verBuf, Int32(verBuf.count)
        )
        let message = String(decoding: msgBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let signedId = String(decoding: bidBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let signedVersion = String(decoding: verBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (status == 0, message.isEmpty ? (status == 0 ? "Signed." : "Failed.") : message,
                signedId, signedVersion.isEmpty ? "1.0" : signedVersion)
        #endif
    }

    // MARK: - Signed-output cache

    /// Streaming SHA-256 so a 400 MB IPA is never held in memory.
    nonisolated static func fileDigest(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 4 * 1024 * 1024),
                  !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func cacheDirectory() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iStore/signed-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Wraps `sign` with a content-addressed cache. Identical input IPA plus
    /// identical certificate plus identical parameters returns the previous
    /// result without touching zsign at all.
    nonisolated static func signCached(ipa: URL, p12: URL, password: String, profile: URL,
                                       bundleId: String, displayName: String, shortVersion: String,
                                       icon: URL?, output: URL, tempDir: URL,
                                       removeExtensions: Bool, enableDocuments: Bool,
                                       dylib: URL?, injectIntoExtensions: Bool)
        -> (ok: Bool, message: String, signedBundleId: String, signedVersion: String) {

        let parameterFingerprint = [
            bundleId, displayName, shortVersion,
            icon?.lastPathComponent ?? "-",
            dylib.flatMap { fileDigest($0) } ?? "-",
            injectIntoExtensions ? "1" : "0",
            removeExtensions ? "1" : "0",
            enableDocuments ? "1" : "0",
        ].joined(separator: "|")

        var key: String?
        if let ipaDigest = fileDigest(ipa), let p12Digest = fileDigest(p12) {
            var hasher = SHA256()
            hasher.update(data: Data("\(ipaDigest)|\(p12Digest)|\(parameterFingerprint)".utf8))
            key = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        let fm = FileManager.default
        let cacheDir = cacheDirectory()

        // Cache hit: link the stored artifact to the caller's fresh output
        // path. Each install attempt still gets its own path, as the existing
        // attemptID logic requires, but no bytes are rewritten.
        if let key {
            let cached = cacheDir.appendingPathComponent("\(key).ipa")
            let meta = cacheDir.appendingPathComponent("\(key).meta")
            if fm.fileExists(atPath: cached.path),
               let raw = try? String(contentsOf: meta, encoding: .utf8) {
                let parts = raw.components(separatedBy: "\n")
                if parts.count >= 2 {
                    try? fm.removeItem(at: output)
                    let linked = (try? fm.linkItem(at: cached, to: output)) != nil
                        || (try? fm.copyItem(at: cached, to: output)) != nil
                    if linked {
                        return (true, "Signed (cached).", parts[0], parts[1])
                    }
                }
            }
        }

        let result = sign(ipa: ipa, p12: p12, password: password, profile: profile,
                          bundleId: bundleId, displayName: displayName,
                          shortVersion: shortVersion, icon: icon, output: output,
                          tempDir: tempDir, removeExtensions: removeExtensions,
                          enableDocuments: enableDocuments,
                          dylib: dylib, injectIntoExtensions: injectIntoExtensions)

        if result.ok, let key, fm.fileExists(atPath: output.path) {
            let cached = cacheDir.appendingPathComponent("\(key).ipa")
            try? fm.removeItem(at: cached)
            if (try? fm.linkItem(at: output, to: cached)) != nil
                || (try? fm.copyItem(at: output, to: cached)) != nil {
                try? "\(result.signedBundleId)\n\(result.signedVersion)"
                    .write(to: cacheDir.appendingPathComponent("\(key).meta"),
                           atomically: true, encoding: .utf8)
            }
        }

        return result
    }

    /// Drops cached artifacts once the cache exceeds `limit` bytes, oldest first.
    nonisolated static func trimCache(limit: Int64 = 4 * 1024 * 1024 * 1024) {
        let fm = FileManager.default
        let dir = cacheDirectory()
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey]) else { return }
        var items: [(url: URL, size: Int64, accessed: Date)] = entries.compactMap {
            guard let values = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey]) else { return nil }
            return ($0, Int64(values.fileSize ?? 0), values.contentAccessDate ?? .distantPast)
        }
        var total = items.reduce(Int64(0)) { $0 + $1.size }
        guard total > limit else { return }
        items.sort { $0.accessed < $1.accessed }
        for item in items where total > limit {
            try? fm.removeItem(at: item.url)
            try? fm.removeItem(at: item.url.deletingPathExtension().appendingPathExtension("meta"))
            total -= item.size
        }
    }

    func cleanStaged() {
        if let items = try? FileManager.default.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) {
            for item in items where item.lastPathComponent != "tmp" {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }
}
