import Foundation

/// Automatic, silent cleanup manager.
/// - Runs on launch, on resume, and after IPA delivery.
/// - Only deletes temporary/signing artifacts, .ipa files, extracted .app bundles, and stale cache files.
/// - Never deletes preferences, certificates, or other user configuration.
final class CleanupManager {
    static let shared = CleanupManager()
    private let fileManager = FileManager.default

    /// Age (in seconds) after which cache files are considered stale and can be removed.
    private let staleCacheInterval: TimeInterval = 3 * 60 * 60 // 3 hours

    /// Fallback timeout after IPA delivered; if the app doesn't resume for some reason,
    /// delete the IPA after this many seconds.
    private let ipaFallbackDeletionDelay: TimeInterval = 300 // 5 minutes

    /// Pending IPA URL to delete after install finishes (or fallback).
    private var pendingIPA: URL?
    private var pendingIPAWorkItem: DispatchWorkItem?

    /// Tracks currently active transfers (files being streamed by the local server).
    /// Guarded by `syncQueue` for thread-safety.
    private var activeTransfers: Set<String> = []
    private let syncQueue = DispatchQueue(label: "com.hggdet.iStore.CleanupManager.sync")

    private init() {}

    // MARK: - External entry points

    /// Thorough cleanup run for cold launches. Runs on a background queue.
    func performLaunchCleanup() {
        DispatchQueue.global(qos: .background).async {
            self.cleanupDocumentsAndTransientDirectories()
        }
    }

    /// Quick cleanup run for resume / become-active events.
    func performResumeCleanup() {
        DispatchQueue.global(qos: .background).async {
            self.cleanupTempAndCaches(quick: true)
        }
    }

    /// Called when an IPA has been delivered by the local server to the installer.
    /// We mark it and delete it once the install step finishes (app re-activates),
    /// or after a fallback delay.
    func markIPAForPostInstallDeletion(_ ipaURL: URL) {
        // All access to pendingIPA and pendingIPAWorkItem must be synchronized.
        syncQueue.async {
            // Keep only one pending IPA at a time; the last one wins.
            self.pendingIPA = ipaURL
            self.pendingIPAWorkItem?.cancel()

            // Predeclare the work item so it can reference itself if needed.
            var work: DispatchWorkItem!
            work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                let deadline = Date().addingTimeInterval(self.ipaFallbackDeletionDelay)

                func attemptDelete() {
                    // If transfer is active, retry shortly until deadline.
                    let id = ipaURL.path
                    var isActive = false
                    self.syncQueue.sync { isActive = self.activeTransfers.contains(id) }

                    if isActive && Date() < deadline {
                        // Transfer is active; reschedule a short check.
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                            if work.isCancelled { return }
                            // Re-run the same work item by calling perform(). This is safe and
                            // intentionally retries until the deadline.
                            work.perform()
                        }
                        return
                    }

                    // Either transfer is not active, or deadline passed — safe to delete.
                    self.deleteFileIfExists(ipaURL)

                    self.syncQueue.async {
                        self.pendingIPA = nil
                        self.pendingIPAWorkItem = nil
                    }
                }

                attemptDelete()
            }

            self.pendingIPAWorkItem = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.ipaFallbackDeletionDelay, execute: work)
        }
    }

    /// Called on applicationDidBecomeActive to indicate installer likely finished.
    /// Deletes any pending IPA immediately.
    func checkPendingIPADeletionOnActivation() {
        syncQueue.async {
            if let url = self.pendingIPA {
                self.deleteFileIfExists(url)
                self.pendingIPA = nil
            }
            self.pendingIPAWorkItem?.cancel()
            self.pendingIPAWorkItem = nil
        }
    }

    // MARK: - Transfer notifications (used by LocalInstallServer)

    /// Notify that a transfer for the given URL has started streaming.
    func notifyTransferStarted(_ url: URL) {
        let id = url.path
        syncQueue.async {
            self.activeTransfers.insert(id)
        }
    }

    /// Notify that a transfer for the given URL has finished streaming.
    func notifyTransferFinished(_ url: URL) {
        let id = url.path
        syncQueue.async {
            self.activeTransfers.remove(id)
        }
    }

    // MARK: - Cleanup implementations

    private func cleanupDocumentsAndTransientDirectories() {
        // Directories to examine: Documents, Caches, temporaryDirectory
        var toScan: [URL] = []

        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            toScan.append(docs)
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            toScan.append(caches)
        }
        // System temp
        toScan.append(fileManager.temporaryDirectory)

        for dir in toScan {
            scanDirectory(dir, removeOldCaches: true)
        }
    }

    private func cleanupTempAndCaches(quick: Bool) {
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            scanDirectory(caches, removeOldCaches: true, quick: quick)
        }
        scanDirectory(fileManager.temporaryDirectory, removeOldCaches: false, quick: quick)
    }

    /// Scans a directory and removes:
    /// - Files with extension .ipa
    /// - Extracted app bundles (.app directories)
    /// - Temporary signing files (heuristic: files inside iStore tmp/work dirs)
    /// - Cache files older than staleCacheInterval when removeOldCaches == true
    private func scanDirectory(_ url: URL, removeOldCaches: Bool, quick: Bool = false) {
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey, .nameKey]
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: resourceKeys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let item = enumerator?.nextObject() as? URL {
            autoreleasepool {
                // Quick mode: only top-level in temp/caches; skip deep traversal to avoid long pauses
                if quick {
                    if item.deletingLastPathComponent() != url { return }
                }

                let name = item.lastPathComponent.lowercased()
                let ext = item.pathExtension.lowercased()

                // Delete .ipa files everywhere
                if ext == "ipa" {
                    deleteFileIfExists(item)
                    return
                }

                // Delete extracted payloads / .app bundles found in temp or caches
                if ext == "app" {
                    let path = item.path
                    if path.hasPrefix(fileManager.temporaryDirectory.path) ||
                        path.contains("/Payload/") ||
                        (url.lastPathComponent.lowercased().contains("cache") || url.lastPathComponent.lowercased().contains("tmp")) {
                        deleteDirectoryIfExists(item)
                    }
                    return
                }

                // Remove old cache files
                if removeOldCaches {
                    let threshold = Date().addingTimeInterval(-staleCacheInterval)
                    if let resourceValues = try? item.resourceValues(forKeys: Set(resourceKeys)),
                       let creation = resourceValues.creationDate ?? resourceValues.contentModificationDate,
                       creation < threshold {
                        var isDir: ObjCBool = false
                        if fileManager.fileExists(atPath: item.path, isDirectory: &isDir) {
                            if !isDir.boolValue {
                                deleteFileIfExists(item)
                            } else {
                                if pathIsEmptyDirectory(item) || item.path.hasPrefix(fileManager.temporaryDirectory.path) {
                                    deleteDirectoryIfExists(item)
                                }
                            }
                        }
                    }
                }

                // Heuristic: Remove transient signing artifacts created under tmp/iStore
                if item.path.contains("/iStore/") && (item.path.contains("/tmp/") || item.path.contains("/temp/")) {
                    if item.path.hasPrefix(fileManager.temporaryDirectory.path) {
                        if isDirectoryURL(item) {
                            deleteDirectoryIfExists(item)
                        } else {
                            deleteFileIfExists(item)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func deleteFileIfExists(_ url: URL) {
        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            // Swallow errors silently — deletions are best-effort and must not crash the app.
        }
    }

    private func deleteDirectoryIfExists(_ url: URL) {
        deleteFileIfExists(url)
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue
        }
        return false
    }

    private func pathIsEmptyDirectory(_ url: URL) -> Bool {
        guard isDirectoryURL(url) else { return false }
        if let list = try? fileManager.contentsOfDirectory(atPath: url.path) {
            return list.isEmpty
        }
        return false
    }
}
