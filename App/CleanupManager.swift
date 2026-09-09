*** Begin Patch
*** Update File: App/CleanupManager.swift
@@
-        syncQueue.async {
-            self.pendingRemoteObjectKey = objectKey
-            self.pendingRemoteWorkItem?.cancel()
-
-            // Simpler fallback: schedule a single best-effort deletion after the configured delay.
-            var work: DispatchWorkItem!
-            work = DispatchWorkItem { [weak self] in
-                guard let self = self else { return }
-                // Capture key inside synchronized block to avoid races.
-                var keyToDelete: String?
-                self.syncQueue.sync { keyToDelete = self.pendingRemoteObjectKey }
-                if let key = keyToDelete {
-                    Task { try? await R2Client.shared.delete(objectKey: key) }
-                }
-                self.syncQueue.async {
-                    self.pendingRemoteObjectKey = nil
-                    self.pendingRemoteWorkItem = nil
-                }
-            }
-
-            self.pendingRemoteWorkItem = work
-            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.ipaFallbackDeletionDelay, execute: work)
-        }
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
+                cleanupDebugLog("Scheduled fallback delete for remote key (delayed): \(keyToDelete ?? "<nil>")")
+                if let key = keyToDelete {
+                    Task {
+                        do {
+                            try await R2Client.shared.delete(objectKey: key)
+                            cleanupDebugLog("Fallback delete succeeded for key: \(key)")
+                        } catch {
+                            cleanupDebugLog("Fallback delete failed for key: \(key) err: \(error)")
+                        }
+                    }
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
*** End Patch