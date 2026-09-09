*** Begin Patch
*** Update File: App/CleanupManager.swift
@@
-import Foundation
+import Foundation
+import os
@@
     private init() {}
+
+private let cleanupLog = OSLog(subsystem: "com.hggdet.iStore", category: "CleanupManager")
+private func cleanupDebugLog(_ message: String) {
+    #if DEBUG
+    print("[CleanupManager] \(message)")
+    #endif
+    os_log("%{public}s", log: cleanupLog, type: .debug, message)
+}
*** End Patch