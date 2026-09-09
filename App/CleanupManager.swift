*** Begin Patch
*** Update File: App/CleanupManager.swift
@@
     private init() {}
@@
     /// Thorough cleanup run for cold launches. Runs on a background queue.
     func performLaunchCleanup() {
         DispatchQueue.global(qos: .background).async {
             self.cleanupDocumentsAndTransientDirectories()
+            // Also sweep remote R2 objects that may be orphaned.
+            self.performRemoteSweepOfOrphanedObjects()
         }
     }
@@
     func markRemoteObjectForPostInstallDeletion(_ objectKey: String) {
-    syncQueue.async {
-        self.pendingRemoteObjectKey = objectKey
-        self.pendingRemoteWorkItem?.cancel()
-
-        var work: DispatchWorkItem!
-        work = DispatchWorkItem { [weak self] in
-            guard let self = self else { return }
-            let deadline = Date().addingTimeInterval(self.ipaFallbackDeletionDelay)
-
-            func attemptDelete() {
-                // No per-file transfer guard for remote uploads; just attempt delete.
-                if let key = self.pendingRemoteObjectKey {
-                    Task {
-                        try? await R2Client.shared.delete(objectKey: key)
-                    }
-                }
-                self.syncQueue.async {
-                    self.pendingRemoteObjectKey = nil
-                    self.pendingRemoteWorkItem = nil
-                }
-            }
-
-            // Schedule deletion: either run now or after retries until deadline
-            attemptDelete()
-        }
-        self.pendingRemoteWorkItem = work
-        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.ipaFallbackDeletionDelay, execute: work)
-    }
+        // Keep access to pendingRemote* synchronized like other state.
+        syncQueue.async {
+            self.pendingRemoteObjectKey = objectKey
+            self.pendingRemoteWorkItem?.cancel()
+
+            // Simpler fallback: schedule a single best-effort deletion after the configured delay.
+            var work: DispatchWorkItem!
+            work = DispatchWorkItem { [weak self] in
+                guard let self = self else { return }
+                // Capture key inside synchronized block to avoid races.
+                var keyToDelete: String?
+                self.syncQueue.sync { keyToDelete = self.pendingRemoteObjectKey }
+                if let key = keyToDelete {
+                    Task { try? await R2Client.shared.delete(objectKey: key) }
+                }
+                self.syncQueue.async {
+                    self.pendingRemoteObjectKey = nil
+                    self.pendingRemoteWorkItem = nil
+                }
+            }
+
+            self.pendingRemoteWorkItem = work
+            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.ipaFallbackDeletionDelay, execute: work)
+        }
     }
@@
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
+
+    // MARK: - Remote cleanup (R2)
+
+    private var pendingRemoteObjectKey: String?
+    private var pendingRemoteWorkItem: DispatchWorkItem?
+
+    /// Called on applicationDidBecomeActive to delete any pending remote object immediately.
+    func checkPendingRemoteDeletionOnActivation() {
+        syncQueue.async {
+            if let key = self.pendingRemoteObjectKey {
+                Task { try? await R2Client.shared.delete(objectKey: key) }
+                self.pendingRemoteObjectKey = nil
+            }
+            self.pendingRemoteWorkItem?.cancel()
+            self.pendingRemoteWorkItem = nil
+        }
+    }
+
+    /// Clear pending remote object without attempting deletion (used after manual delete).
+    func clearPendingRemoteObject() {
+        syncQueue.async {
+            self.pendingRemoteObjectKey = nil
+            self.pendingRemoteWorkItem?.cancel()
+            self.pendingRemoteWorkItem = nil
+        }
+    }
+
+    /// Cold-start sweep to remove orphaned remote objects older than 1 hour.
+    func performRemoteSweepOfOrphanedObjects() {
+        DispatchQueue.global(qos: .background).async {
+            Task {
+                do {
+                    let items = try await R2Client.shared.list(prefix: "istore/")
+                    let threshold = Date().addingTimeInterval(-60 * 60) // 1 hour
+                    for (key, modified) in items {
+                        if modified < threshold {
+                            try await R2Client.shared.delete(objectKey: key)
+                        }
+                    }
+                } catch {
+                    // Best-effort: ignore and try again next launch.
+                }
+            }
+        }
+    }
*** End Patch