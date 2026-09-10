import SwiftUI
import UIKit

final class ForgeApplicationDelegate: NSObject, UIApplicationDelegate {
    private var pendingShortcutURL: URL?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let shortcut = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            pendingShortcutURL = socialURL(for: shortcut.type)
        }
        configureQuickActions(application)
        CleanupManager.shared.performLaunchCleanup()
        return true
    }

    private func configureQuickActions(_ application: UIApplication) {
        let telegram = UIApplicationShortcutItem(
            type: "com.hggdet.istore.telegram",
            localizedTitle: "Telegram",
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(templateImageName: "QuickActionTelegram"),
            userInfo: nil
        )
        let tiktok = UIApplicationShortcutItem(
            type: "com.hggdet.istore.tiktok",
            localizedTitle: "TikTok",
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(templateImageName: "QuickActionTikTok"),
            userInfo: nil
        )
        application.shortcutItems = [telegram, tiktok]
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        CleanupManager.shared.performResumeCleanup()
        CleanupManager.shared.checkPendingIPADeletionOnActivation()
        guard let url = pendingShortcutURL else { return }
        pendingShortcutURL = nil
        openSocialURL(url, using: application)
    }

    func application(_ application: UIApplication,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let url = socialURL(for: shortcutItem.type) else {
            completionHandler(false)
            return
        }
        // Give SpringBoard time to finish dismissing the shortcut menu before
        // handing the URL to the external app/browser.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            application.open(url, options: [:]) { success in
                completionHandler(success)
            }
        }
    }

    private func openSocialURL(_ url: URL, using application: UIApplication) {
        // Opening too early during cold launch can be ignored by iOS and leave
        // the user on iStore. The short delay makes cold and warm launches
        // follow the same reliable path.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            application.open(url, options: [:])
        }
    }

    private func socialURL(for type: String) -> URL? {
        switch type {
        case "com.hggdet.istore.telegram":
            return URL(string: "https://t.me/ipafilesfor")
        case "com.hggdet.istore.tiktok":
            return URL(string: "https://www.tiktok.com/@087.n")
        default:
            return nil
        }
    }
}

@main
struct ForgeSignMobileApp: App {
    @UIApplicationDelegateAdaptor(ForgeApplicationDelegate.self) private var appDelegate
    @AppStorage("app.language") private var languageCode = AppLanguage.arabic.rawValue

    init() {
        let defaults = UserDefaults.standard
        // Existing builds used English as their implicit default. Migrate only
        // users who never explicitly selected a language; a deliberate choice
        // remains untouched on every later launch.
        if defaults.object(forKey: "app.language.userSelected") == nil {
            defaults.set(AppLanguage.arabic.rawValue, forKey: "app.language")
        }
    }

    @StateObject private var certificates = CertificateStore()
    @StateObject private var profiles = ProfileStore()
    @StateObject private var history = HistoryStore()
    @StateObject private var installer = InstallController()
    @StateObject private var repositories = RepositoryStore()

    var body: some Scene {
        let language = AppLanguage(rawValue: languageCode) ?? .english

        WindowGroup {
            ForgeRootView()
                .environment(\.appLanguage, language)
                .environment(\.locale, language.locale)
                .environment(\.layoutDirection, language.layoutDirection)
                .environmentObject(certificates)
                .environmentObject(profiles)
                .environmentObject(history)
                .environmentObject(installer)
                .environmentObject(repositories)
        }
    }
}

/// Root: Apps + Sign + About tabs, theme injection + Dynamic Type cap.
/// The ambient glass backdrop is mounted inside each tab's NavigationStack.
private struct ForgeRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var installer: InstallController
    @EnvironmentObject private var repositories: RepositoryStore
    @State private var tab = 0

    private var theme: ForgeTheme { colorScheme == .dark ? .dark : .light }

    var body: some View {
        TabView(selection: Binding(
            get: { tab },
            set: { newValue in
                withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) {
                    tab = newValue
                }
            }
        )) {
            AppsView()
                .tabItem {
                    Label {
                        Text("Apps")
                    } icon: {
                        Image(systemName: tab == 0 ? "square.grid.2x2.fill" : "square.grid.2x2")
                            .scaleEffect(tab == 0 ? 1.1 : 1.0)
                            .animation(.spring(response: 0.32, dampingFraction: 0.68), value: tab)
                            .id("apps-tab-icon-\(tab)")
                    }
                    .id(tab == 0)
                }
                .tag(0)

            ContentView()
                .tabItem {
                    Label {
                        Text("Sign")
                    } icon: {
                        Image(systemName: tab == 1 ? "circle.fill" : "circle")
                            .scaleEffect(tab == 1 ? 1.1 : 1.0)
                            .animation(.spring(response: 0.32, dampingFraction: 0.68), value: tab)
                            .overlay {
                                Image(systemName: "signature")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .id("sign-tab-icon-\(tab)")
                    }
                    .id(tab == 1)
                }
                .tag(1)

            AboutView()
                .tabItem {
                    Label {
                        Text("About")
                    } icon: {
                        Image(systemName: tab == 2 ? "person.crop.circle.fill" : "person.crop.circle")
                            .scaleEffect(tab == 2 ? 1.1 : 1.0)
                            .animation(.spring(response: 0.32, dampingFraction: 0.68), value: tab)
                            .id("about-tab-icon-\(tab)")
                    }
                    .id(tab == 2)
                }
                .tag(2)
        }
        .tint(theme.accent)
        .forgeTheme(theme)
        .forgeScaledType()
    }

}
