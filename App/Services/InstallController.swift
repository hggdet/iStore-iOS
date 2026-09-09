import Foundation
import SwiftUI

@MainActor
final class InstallController: ObservableObject {
    @Published var installStatus = ""

    private var installTask: Task<Void, Never>?
    private var installGeneration = UUID()

    /// Called when the currently uploaded IPA has been fully delivered/handed off.
    var onDelivered: (() -> Void)?

    func install(ipa: URL, bundleId: String, version: String, title: String = "iStore") {
        installTask?.cancel()
        let generation = UUID()
        installGeneration = generation
        installStatus = "Preparing upload…"

        installTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                if self.installGeneration == generation {
                    self.installTask = nil
                }
            }

            do {
                guard self.installGeneration == generation, !Task.isCancelled else { return }

                // Upload signed IPA to R2
                let objectKey = "istore/\(UUID().uuidString).ipa"
                installStatus = "Uploading IPA…"

                let uploadedKey = try await R2Client.shared.upload(file: ipa, objectKey: objectKey) { [weak self] progress in
                    Task { @MainActor in
                        guard let self = self else { return }
                        let pct = Int(progress * 100)
                        self.installStatus = "Uploading IPA — \(pct)%"
                    }
                }

                // Delete the staged IPA file copy immediately (best-effort)
                try? FileManager.default.removeItem(at: ipa)
                // Also call SigningService.cleanStaged() to remove any other leftover staging artifacts.
                Task { @MainActor in SigningService().cleanStaged() }

                guard self.installGeneration == generation, !Task.isCancelled else {
                    // best-effort delete uploaded object if we were cancelled
                    Task { try? await R2Client.shared.delete(objectKey: uploadedKey) }
                    // Ensure local staged files are removed when cancelled
                    Task { @MainActor in SigningService().cleanStaged() }
                    return
                }

                // Mark uploaded object for post-install deletion
                CleanupManager.shared.markRemoteObjectForPostInstallDeletion(uploadedKey)

                // Generate presigned GET URL for the object (valid for 30 minutes)
                let presigned = try R2Client.shared.presignedGetURL(for: uploadedKey, expires: 60 * 30)

                // Build remote manifest (api.palera.in/genPlist) with fetchurl pointing at presigned URL
                var comps = URLComponents(string: "https://api.palera.in/genPlist")!
                comps.queryItems = [
                    URLQueryItem(name: "bundleid", value: bundleId),
                    URLQueryItem(name: "name", value: title),
                    URLQueryItem(name: "version", value: version),
                    URLQueryItem(name: "fetchurl", value: presigned.absoluteString),
                ]
                guard let remoteManifestURL = comps.url?.absoluteString else {
                    throw NSError(domain: "forgesign.install", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad remote manifest URL."])
                }

                // Open itms-services handoff
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
                let encoded = remoteManifestURL.addingPercentEncoding(withAllowedCharacters: allowed) ?? remoteManifestURL
                guard let itmsURL = URL(string: "itms-services://?action=download-manifest&url=\(encoded)") else {
                    throw NSError(domain: "forgesign.install", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad itms-services URL."])
                }

                installStatus = "Triggering installer…"
                UIApplication.shared.open(itmsURL) { [weak self] opened in
                    Task { @MainActor in
                        guard let self = self else { return }
                        if opened {
                            self.installStatus = "Install prompted. Accept the iOS dialog if shown."
                        } else {
                            // Direct open was gated — open the HTTPS manifest in Safari as a fallback.
                            self.installStatus = "Direct open gated — opening manifest in Safari…"
                            if let page = URL(string: remoteManifestURL) {
                                UIApplication.shared.open(page) { pageOpened in
                                    if !pageOpened {
                                        Task { @MainActor in
                                            guard self.installGeneration == generation else { return }
                                            self.installStatus = "Install failed: iOS could not open the installation page."
                                            // Try to remove uploaded object since install did not proceed
                                            Task { try? await R2Client.shared.delete(objectKey: uploadedKey) }
                                            CleanupManager.shared.clearPendingRemoteObject()
                                            Task { @MainActor in SigningService().cleanStaged() }
                                        }
                                    }
                                }
                            } else {
                                Task { @MainActor in
                                    self.installStatus = "Install failed: could not construct manifest URL."
                                    Task { try? await R2Client.shared.delete(objectKey: uploadedKey) }
                                    CleanupManager.shared.clearPendingRemoteObject()
                                    SigningService().cleanStaged()
                                }
                            }
                        }
                    }
                }

                // Optionally wait a brief period to let user interact, then return.
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                guard self.installGeneration == generation, !Task.isCancelled else { return }

                // Notify delivered (upload completed and handoff attempted)
                Task { @MainActor in
                    self.installStatus = "IPA delivered. Installing…"
                    InstallKeepAlive.shared.stop() // harmless if not active
                    self.onDelivered?()
                }

            } catch {
                guard self.installGeneration == generation, !Task.isCancelled else { return }
                let msg = (error as NSError).localizedDescription
                installStatus = "Install failed: \(msg)"
                // Ensure we clean any local staged artifacts on error
                Task { @MainActor in SigningService().cleanStaged() }
            }
        }
    }

    /// Re-opens the remote manifest in Safari (fallback).
    func openInstallPage() {
        // Nothing locally hosted any more; this helper is kept for compatibility.
        installStatus = "Opening manifest in Safari…"
        // If there is a pending remote object, UI can call install(...) again if needed.
    }
}
