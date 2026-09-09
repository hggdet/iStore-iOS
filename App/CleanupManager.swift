import Foundation

final class CleanupManager: @unchecked Sendable {
    static let shared = CleanupManager()

    private init() {}

    private let syncQueue = DispatchQueue(label: "com.hggdet.iStore.CleanupManager.sync")
    private let ipaFallbackDeletionDelay: TimeInterval = 60 * 5

    /// Thorough cleanup run for cold launches. Runs on a background queue.
    func performLaunchCleanup() {
        DispatchQueue.global(qos: .background).async {
            self.cleanupDocumentsAndTransientDirectories()
            // Also sweep remote R2 objects that may be orphaned.
            self.performRemoteSweepOfOrphanedObjects()
            // Run a conservative local sweep for old staged artifacts.
            self.performLocalStagedSweep()
        }
    }

    // Placeholder for existing cleanup logic; keep as a no-op here if not present.
    private func cleanupDocumentsAndTransientDirectories() {
        // Existing cleanup logic lives here in the real project.
    }

    func markRemoteObjectForPostInstallDeletion(_ objectKey: String) {
        // Keep access to pendingRemote* synchronized like other state.
        syncQueue.async {
            self.pendingRemoteObjectKey = objectKey
            self.pendingRemoteWorkItem?.cancel()

            // Simpler fallback: schedule a single best-effort deletion after the configured delay.
            var work: DispatchWorkItem!
            work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // Capture key inside synchronized block to avoid races.
                var keyToDelete: String?
                self.syncQueue.sync { keyToDelete = self.pendingRemoteObjectKey }
                if let key = keyToDelete {
                    Task { try? await R2Client.shared.delete(objectKey: key) }
                }
                self.syncQueue.async {
                    self.pendingRemoteObjectKey = nil
                    self.pendingRemoteWorkItem = nil
                }
            }

            self.pendingRemoteWorkItem = work
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.ipaFallbackDeletionDelay, execute: work)
        }
    }

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

    // MARK: - Remote cleanup (R2)

    private var pendingRemoteObjectKey: String?
    private var pendingRemoteWorkItem: DispatchWorkItem?

    /// Called on applicationDidBecomeActive to delete any pending remote object immediately.
    func checkPendingRemoteDeletionOnActivation() {
        syncQueue.async {
            if let key = self.pendingRemoteObjectKey {
                Task { try? await R2Client.shared.delete(objectKey: key) }
                self.pendingRemoteObjectKey = nil
            }
            self.pendingRemoteWorkItem?.cancel()
            self.pendingRemoteWorkItem = nil
        }
    }

    /// Clear pending remote object without attempting deletion (used after manual delete).
    func clearPendingRemoteObject() {
        syncQueue.async {
            self.pendingRemoteObjectKey = nil
            self.pendingRemoteWorkItem?.cancel()
            self.pendingRemoteWorkItem = nil
        }
    }

    /// Cold-start sweep to remove orphaned remote objects older than 1 hour.
    func performRemoteSweepOfOrphanedObjects() {
        DispatchQueue.global(qos: .background).async {
            Task {
                do {
                    let items = try await R2Client.shared.list(prefix: "istore/")
                    let threshold = Date().addingTimeInterval(-60 * 60) // 1 hour
                    for (key, modified) in items {
                        if modified < threshold {
                            try await R2Client.shared.delete(objectKey: key)
                        }
                    }
                } catch {
                    // Best-effort: ignore and try again next launch.
                }
            }
        }
    }

    /// Sweep local staged/signed IPA files in SigningService.workDir older than 1 hour.
    /// Conservative: only removes .ipa files and directories that look like .app bundles.
    func performLocalStagedSweep() {
        DispatchQueue.global(qos: .background).async {
            let signer = SigningService()
            let dir = signer.workDir
            let fileManager = FileManager.default
            let threshold = Date().addingTimeInterval(-60 * 60) // 1 hour
            var deleted = 0
            if let items = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
                for item in items {
                    // skip the tmp directory
                    if item.lastPathComponent == "tmp" { continue }
                    // Only remove obvious staged artifacts: .ipa files OR directories that look like .app bundles
                    let ext = item.pathExtension.lowercased()
                    var isDir = false
                    if let res = try? item.resourceValues(forKeys: [.isDirectoryKey]), let v = res.isDirectory { isDir = v }
                    if ext == "ipa" || (isDir && item.lastPathComponent.hasSuffix(".app")) {
                        let resource = try? item.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
                        let date = resource?.contentModificationDate ?? resource?.creationDate
                        if let d = date, d < threshold {
                            try? fileManager.removeItem(at: item)
                            deleted += 1
                        }
                    }
                }
            }
            // If cleanupDebugLog exists in the project, call it; otherwise no-op.
            if let fn = NSClassFromString("DebugLogger") {
                // noop; keep compatibility if project provides logging
                _ = fn
            }
        }
    }

    // MARK: - IPA local cleanup placeholders

    private var pendingIPA: URL?
    private var pendingIPAWorkItem: DispatchWorkItem?

    private func deleteFileIfExists(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
