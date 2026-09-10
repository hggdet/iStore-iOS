import Foundation
import SwiftUI
import UIKit

/// Owns the semi-local OTA install flow (local HTTP IPA + remote HTTPS
/// plist via `api.palera.in`). Opens `itms-services` directly for a seamless
/// install prompt (1.0 behaviour); Safari is the fallback only.
@MainActor
final class InstallController: ObservableObject {
    @Published var installServer: LocalInstallServer?
    @Published var installStatus = ""

    private var installTask: Task<Void, Never>?
    private var installGeneration = UUID()

    /// Called when the currently served IPA has been fully downloaded.
    var onDelivered: (() -> Void)?

    func install(ipa: URL, bundleId: String, version: String, title: String = "iStore") {
        installTask?.cancel()
        installServer?.stop()
        installServer = nil
        InstallKeepAlive.shared.stop()

        let generation = UUID()
        installGeneration = generation
        installStatus = "Starting install server…"

        // Keep the app (and its local server) alive while the iOS installer
        // downloads. A background task alone only buys ~30 seconds; silent
        // audio playback holds the `audio` background mode for large IPAs.
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "forgesign.install") {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        InstallKeepAlive.shared.start()

        installTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if bgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTask)
                    bgTask = .invalid
                }
                if self.installGeneration == generation {
                    self.installTask = nil
                }
            }
            do {
                guard self.installGeneration == generation, !Task.isCancelled else { return }
                let server = LocalInstallServer()
                _ = try await server.start(ipa: ipa, bundleId: bundleId,
                                           bundleVersion: version,
                                           title: title)
                guard self.installGeneration == generation, !Task.isCancelled else {
                    server.stop()
                    return
                }
                installServer = server
                    server.onIPADelivered = { [weak self] in
                        Task { @MainActor in
                            guard let self, self.installGeneration == generation else { return }
                            CleanupManager.shared.markIPAForPostInstallDeletion(ipa)
                            self.installStatus = "IPA delivered. Installing… accept the iOS prompt if shown."
                            InstallKeepAlive.shared.stop()
                            self.onDelivered?()
                    }
                }

                // Confirm the local IPA endpoint answers before handing off.
                let health = URL(string: "\(server.installBaseURL)/health")!
                let (_, healthResp) = try await URLSession.shared.data(from: health)
                guard (healthResp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain: "forgesign.install", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Local install server failed self-check."])
                }

                // Do not fetch the remote plist here before opening the handoff.
                // That duplicated the request iOS immediately makes itself and
                // added avoidable latency before the install prompt appeared.
                // Validate the URL shape locally, then let iOS resolve it once.
                guard URL(string: server.remoteManifestURL) != nil else {
                    throw NSError(domain: "forgesign.install", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad remote manifest URL."])
                }

                // Open itms-services immediately after the local endpoint is ready.
                // iOS resolves the trusted remote HTTPS manifest itself; Safari is
                // only a fallback if the direct open is gated.
                guard let itmsURL = URL(string: server.itmsServicesURL) else {
                    throw NSError(domain: "forgesign.install", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Bad itms-services URL."])
                }
                installStatus = "Triggering installer…"
                UIApplication.shared.open(itmsURL) { [weak self] opened in
                    Task { @MainActor in
                        guard let self else { return }
                        if opened {
                            self.installStatus = "Install prompted. Accept the iOS dialog and keep the app open."
                        } else {
                            self.installStatus = "Direct open gated — opening Safari install page…"
                            if let page = URL(string: "\(server.installBaseURL)/install") {
                                UIApplication.shared.open(page) { [weak self] pageOpened in
                                    guard !pageOpened else { return }
                                    Task { @MainActor in
                                        guard let self, self.installGeneration == generation else { return }
                                        self.installStatus = "Install failed: iOS could not open the installation page."
                                        self.installServer?.stop()
                                        self.installServer = nil
                                        InstallKeepAlive.shared.stop()
                                    }
                                }
                            } else {
                                self.installStatus = "Install failed: iOS could not open the installation page."
                                self.installServer?.stop()
                                self.installServer = nil
                                InstallKeepAlive.shared.stop()
                            }
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard self.installGeneration == generation, !Task.isCancelled else { return }
            } catch {
                guard self.installGeneration == generation, !Task.isCancelled else { return }
                installStatus = "Install failed: \(error.localizedDescription)"
                installServer?.stop()
                installServer = nil
                InstallKeepAlive.shared.stop()
            }
        }
    }

    /// Re-opens the local HTTP install page in Safari.
    func openInstallPage() {
        guard let server = installServer else { return }
        guard let page = URL(string: "\(server.installBaseURL)/install") else { return }
        installStatus = "Opening install page in Safari…"
        UIApplication.shared.open(page)
    }
}
