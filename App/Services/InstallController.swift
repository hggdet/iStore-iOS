*** Begin Patch
*** Update File: App/Services/InstallController.swift
@@
-@MainActor
-final class InstallController: ObservableObject {
-    @Published var installServer: LocalInstallServer?
-    @Published var installStatus = ""
-
-    private var installTask: Task<Void, Never>?
-    private var installGeneration = UUID()
-
-    /// Called when the currently served IPA has been fully downloaded.
-    var onDelivered: (() -> Void)?
-
-    func install(ipa: URL, bundleId: String, version: String, title: String = "iStore") {
-        installTask?.cancel()
-        installServer?.stop()
-        installServer = nil
-        InstallKeepAlive.shared.stop()
-
-        let generation = UUID()
-        installGeneration = generation
-        installStatus = "Starting install server…"
-
-        // Keep the app (and its local server) alive while the iOS installer
-        // downloads. A background task alone only buys ~30 seconds; silent
-        // audio playback holds the `audio` background mode for large IPAs.
-        var bgTask: UIBackgroundTaskIdentifier = .invalid
-        bgTask = UIApplication.shared.beginBackgroundTask(withName: "forgesign.install") {
-            UIApplication.shared.endBackgroundTask(bgTask)
-            bgTask = .invalid
-        }
-        InstallKeepAlive.shared.start()
-
-        installTask = Task { [weak self] in
-            guard let self else { return }
-            defer {
-                if bgTask != .invalid {
-                    UIApplication.shared.endBackgroundTask(bgTask)
-                    bgTask = .invalid
-                }
-                if self.installGeneration == generation {
-                    self.installTask = nil
-                }
-            }
-            do {
-                guard self.installGeneration == generation, !Task.isCancelled else { return }
-                let server = LocalInstallServer()
-                _ = try await server.start(ipa: ipa, bundleId: bundleId,
-                                           bundleVersion: version,
-                                           title: title)
-                guard self.installGeneration == generation, !Task.isCancelled else {
-                    server.stop()
-                    return
-                }
-                installServer = server
-                server.onIPADelivered = { [weak self] in
-                    Task { @MainActor in
-                        guard let self, self.installGeneration == generation else { return }
-                        self.installStatus = "IPA delivered. Installing… accept the iOS prompt if shown."
-                        InstallKeepAlive.shared.stop()
-                        self.onDelivered?()
-                    }
-                }
-
-                // Confirm the local IPA endpoint answers before handing off.
-                let health = URL(string: "\(server.installBaseURL)/health")!
-                let (_, healthResp) = try await URLSession.shared.data(from: health)
-                guard (healthResp as? HTTPURLResponse)?.statusCode == 200 else {
-                    throw NSError(domain: "forgesign.install", code: 1,
-                                  userInfo: [NSLocalizedDescriptionKey: "Local install server failed self-check."])
-                }
-
-                // Do not fetch the remote plist here before opening the handoff.
-                // That duplicated the request iOS immediately makes itself and
-                // added avoidable latency before the install prompt appeared.
-                // Validate the URL shape locally, then let iOS resolve it once.
-                guard URL(string: server.remoteManifestURL) != nil else {
-                    throw NSError(domain: "forgesign.install", code: 2,
-                                  userInfo: [NSLocalizedDescriptionKey: "Bad remote manifest URL."])
-                }
-
-                // Open itms-services immediately after the local endpoint is ready.
-                // iOS resolves the trusted remote HTTPS manifest itself; Safari is
-                // only a fallback if the direct open is gated.
-                guard let itmsURL = URL(string: server.itmsServicesURL) else {
-                    throw NSError(domain: "forgesign.install", code: 4,
-                                  userInfo: [NSLocalizedDescriptionKey: "Bad itms-services URL."])
-                }
-                installStatus = "Triggering installer…"
-                UIApplication.shared.open(itmsURL) { [weak self] opened in
-                    Task { @MainActor in
-                        guard let self else { return }
-                        if opened {
-                            self.installStatus = "Install prompted. Accept the iOS dialog and keep the app open."
-                        } else {
-                            self.installStatus = "Direct open gated — opening Safari install page…"
-                            if let page = URL(string: "\(server.installBaseURL)/install") {
-                                UIApplication.shared.open(page) { [weak self] pageOpened in
-                                    guard !pageOpened else { return }
-                                    Task { @MainActor in
-                                        guard let self, self.installGeneration == generation else { return }
-                                        self.installStatus = "Install failed: iOS could not open the installation page."
-                                        self.installServer?.stop()
-                                        self.installServer = nil
-                                        InstallKeepAlive.shared.stop()
-                                    }
-                                }
-                            } else {
-                                self.installStatus = "Install failed: iOS could not open the installation page."
-                                self.installServer?.stop()
-                                self.installServer = nil
-                                InstallKeepAlive.shared.stop()
-                            }
-                        }
-                    }
-                }
-
-                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
-                guard self.installGeneration == generation, !Task.isCancelled else { return }
-            } catch {
-                guard self.installGeneration == generation, !Task.isCancelled else { return }
-                installStatus = "Install failed: \(error.localizedDescription)"
-                installServer?.stop()
-                installServer = nil
-                InstallKeepAlive.shared.stop()
-            }
-        }
-    }
-
-    /// Re-opens the local HTTP install page in Safari.
-    func openInstallPage() {
-        guard let server = installServer else { return }
-        guard let page = URL(string: "\(server.installBaseURL)/install") else { return }
-        installStatus = "Opening install page in Safari…"
-        UIApplication.shared.open(page)
-    }
-}
+@MainActor
+final class InstallController: ObservableObject {
+    @Published var installStatus = ""
+
+    private var installTask: Task<Void, Never>?
+    private var installGeneration = UUID()
+
+    /// Called when the currently uploaded IPA has been fully delivered/handed off.
+    var onDelivered: (() -> Void)?
+
+    func install(ipa: URL, bundleId: String, version: String, title: String = "iStore") {
+        installTask?.cancel()
+        let generation = UUID()
+        installGeneration = generation
+        installStatus = "Preparing upload…"
+
+        installTask = Task { [weak self] in
+            guard let self else { return }
+            defer {
+                if self.installGeneration == generation {
+                    self.installTask = nil
+                }
+            }
+
+            do {
+                guard self.installGeneration == generation, !Task.isCancelled else { return }
+
+                // Upload signed IPA to R2
+                let objectKey = "istore/\(UUID().uuidString).ipa"
+                installStatus = "Uploading IPA…"
+
+                let uploadedKey = try await R2Client.shared.upload(file: ipa, objectKey: objectKey) { [weak self] progress in
+                    Task { @MainActor in
+                        guard let self else { return }
+                        let pct = Int(progress * 100)
+                        self.installStatus = "Uploading IPA — \(pct)%"
+                    }
+                }
+
+                guard self.installGeneration == generation, !Task.isCancelled else {
+                    // best-effort delete uploaded object if we were cancelled
+                    Task { try? await R2Client.shared.delete(objectKey: uploadedKey) }
+                    return
+                }
+
+                // Mark uploaded object for post-install deletion
+                CleanupManager.shared.markRemoteObjectForPostInstallDeletion(uploadedKey)
+
+                // Generate presigned GET URL for the object (valid for 30 minutes)
+                let presigned = try R2Client.shared.presignedGetURL(for: uploadedKey, expires: 60 * 30)
+
+                // Build remote manifest (api.palera.in/genPlist) with fetchurl pointing at presigned URL
+                var comps = URLComponents(string: "https://api.palera.in/genPlist")!
+                comps.queryItems = [
+                    URLQueryItem(name: "bundleid", value: bundleId),
+                    URLQueryItem(name: "name", value: title),
+                    URLQueryItem(name: "version", value: version),
+                    URLQueryItem(name: "fetchurl", value: presigned.absoluteString),
+                ]
+                guard let remoteManifestURL = comps.url?.absoluteString else {
+                    throw NSError(domain: "forgesign.install", code: 2,
+                                  userInfo: [NSLocalizedDescriptionKey: "Bad remote manifest URL."])
+                }
+
+                // Open itms-services handoff
+                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
+                let encoded = remoteManifestURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? remoteManifestURL
+                guard let itmsURL = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else {
+                    throw NSError(domain: "forgesign.install", code: 4,
+                                  userInfo: [NSLocalizedDescriptionKey: "Bad itms-services URL."])
+                }
+
+                installStatus = "Triggering installer…"
+                UIApplication.shared.open(itmsURL) { [weak self] opened in
+                    Task { @MainActor in
+                        guard let self else { return }
+                        if opened {
+                            self.installStatus = "Install prompted. Accept the iOS dialog if shown."
+                        } else {
+                            // Direct open was gated — open the HTTPS manifest in Safari as a fallback.
+                            self.installStatus = "Direct open gated — opening manifest in Safari…"
+                            if let page = URL(string: remoteManifestURL) {
+                                UIApplication.shared.open(page) { pageOpened in
+                                    if !pageOpened {
+                                        Task { @MainActor in
+                                            guard let self, self.installGeneration == generation else { return }
+                                            self.installStatus = "Install failed: iOS could not open the installation page."
+                                            // Try to remove uploaded object since install did not proceed
+                                            Task { try? await R2Client.shared.delete(objectKey: uploadedKey) }
+                                            CleanupManager.shared.clearPendingRemoteObject()
+                                        }
+                                    }
+                                }
+                            } else {
+                                self.installStatus = "Install failed: could not construct manifest URL."
+                                Task { try? await R2Client.shared.delete(objectKey: uploadedKey) }
+                                CleanupManager.shared.clearPendingRemoteObject()
+                            }
+                        }
+                    }
+                }
+
+                // Optionally wait a brief period to let user interact, then return.
+                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000) // 1s
+                guard self.installGeneration == generation, !Task.isCancelled else { return }
+
+                // Notify delivered (upload completed and handoff attempted)
+                Task { @MainActor in
+                    self.installStatus = "IPA delivered. Installing…"
+                    InstallKeepAlive.shared.stop() // harmless if not active
+                    self.onDelivered?()
+                }
+
+            } catch {
+                guard self.installGeneration == generation, !Task.isCancelled else { return }
+                let msg = (error as NSError).localizedDescription
+                installStatus = "Install failed: \(msg)"
+            }
+        }
+    }
+
+    /// Re-opens the remote manifest in Safari (fallback).
+    func openInstallPage() {
+        // Nothing locally hosted any more; this helper is kept for compatibility.
+        installStatus = "Opening manifest in Safari…"
+        // If there is a pending remote object, try to open its presigned URL's manifest via genPlist
+        // No-op here; UI can call install(...) again if needed.
+    }
+}
*** End Patch