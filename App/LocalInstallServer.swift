*** Begin Patch
*** Update File: App/LocalInstallServer.swift
@@
     private func sendFile(_ fd: Int32, url: URL, headOnly: Bool) {
         guard let handle = try? FileHandle(forReadingFrom: url) else {
             sendResponse(fd, status: "404 Not Found", contentType: "text/plain", body: Data(), headOnly: false)
             return
         }
+        // Notify CleanupManager that a transfer is starting to stream this file. This prevents
+        // the fallback deletion from removing the file mid-transfer.
+        CleanupManager.shared.notifyTransferStarted(url)
         let fileSize = handle.seekToEndOfFile()
         handle.seek(toFileOffset: 0)
@@
-        while true {
+        while true {
             let chunk = handle.readData(ofLength: 1024 * 1024)
             if chunk.isEmpty { break }
             sendAll(fd, chunk)
         }
         try? handle.close()
-        onIPADelivered?()
+        onIPADelivered?()
+        // Notify that transfer finished and schedule post-install deletion.
+        CleanupManager.shared.notifyTransferFinished(url)
+        CleanupManager.shared.markIPAForPostInstallDeletion(url)
     }
*** End Patch