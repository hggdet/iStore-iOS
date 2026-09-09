*** Begin Patch
*** Update File: App/Services/InstallController.swift
@@
-                let uploadedKey = try await R2Client.shared.upload(file: ipa, objectKey: objectKey) { [weak self] progress in
-                    Task { @MainActor in
-                        guard let self else { return }
-                        let pct = Int(progress * 100)
-                        self.installStatus = "Uploading IPA — \(pct)%"
-                    }
-                }
-
-                guard self.installGeneration == generation, !Task.isCancelled else {
-                    // best-effort delete uploaded object if we were cancelled
-                    Task { try? await R2Client.shared.delete(objectKey: uploadedKey) }
-                    return
-                }
-
-                // Mark uploaded object for post-install deletion
-                CleanupManager.shared.markRemoteObjectForPostInstallDeletion(uploadedKey)
+                let uploadedKey = try await R2Client.shared.upload(file: ipa, objectKey: objectKey) { [weak self] progress in
+                    Task { @MainActor in
+                        guard let self else { return }
+                        let pct = Int(progress * 100)
+                        self.installStatus = "Uploading IPA — \(pct)%"
+                    }
+                }
+
+                // --- NEW: Remove local staged ipa and tidy signing workdir now that upload succeeded ---
+                // Delete the staged IPA file copy immediately (best-effort)
+                do {
+                    try? FileManager.default.removeItem(at: ipa)
+                }
+                // Also call SigningService.cleanStaged() to remove any other leftover staging artifacts.
+                Task { @MainActor in SigningService().cleanStaged() }
+                // --- end new ---
+
+                guard self.installGeneration == generation, !Task.isCancelled else {
+                    // best-effort delete uploaded object if we were cancelled
+                    Task { try? await R2Client.shared.delete(objectKey: uploadedKey) }
+                    // Ensure local staged files are removed when cancelled
+                    Task { @MainActor in SigningService().cleanStaged() }
+                    return
+                }
+
+                // Mark uploaded object for post-install deletion
+                CleanupManager.shared.markRemoteObjectForPostInstallDeletion(uploadedKey)
*** End Patch