*** Begin Patch
*** Update File: App/CleanupManager.swift
@@
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
+
+    /// Sweep local staged/signed IPA files in SigningService.workDir older than 1 hour.
+    func performLocalStagedSweep() {
+        DispatchQueue.global(qos: .background).async {
+            let signer = SigningService()
+            let dir = signer.workDir
+            let fileManager = FileManager.default
+            let threshold = Date().addingTimeInterval(-60 * 60) // 1 hour
+            var deleted = 0
+            if let items = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .isDirectoryKey], options: [.skipsHiddenFiles]) {
+                for item in items {
+                    // skip the tmp directory
+                    if item.lastPathComponent == "tmp" { continue }
+                    // target likely staged artifacts — .ipa files or extracted .app bundles (directories)
+                    let ext = item.pathExtension.lowercased()
+                    var isDir = false
+                    if let res = try? item.resourceValues(forKeys: [.isDirectoryKey]), let v = res.isDirectory { isDir = v }
+                    if ext == "ipa" || (isDir && item.pathExtension.isEmpty && item.lastPathComponent.hasSuffix(".app")) {
+                        let resource = try? item.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
+                        let date = resource?.contentModificationDate ?? resource?.creationDate
+                        if let d = date, d < threshold {
+                            try? fileManager.removeItem(at: item)
+                            deleted += 1
+                        }
+                    }
+                }
+            }
+            cleanupDebugLog("performLocalStagedSweep: removed \(deleted) old staged items from \(dir.path)")
+        }
+    }
*** End Patch