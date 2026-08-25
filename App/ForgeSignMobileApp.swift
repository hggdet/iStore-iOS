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

/// Root: Home + Apps + Sign + General + About tabs, theme injection and the
/// Dynamic Type cap.
/// The ambient glass backdrop is mounted inside each tab's NavigationStack.
///
/// A custom bottom bar instead of native `TabView`/`tabItem` chrome: a
/// floating Liquid Glass bar, inset from both edges the way iOS 26's own tab
/// bars sit, with App Store behaviour on top of it — outline icons swap to
/// filled ones on the active tab (no separate indicator dot) with a springy
/// bounce, and the screen underneath cross-fades rather than cutting
/// instantly. All four tabs stay mounted the whole time and are just toggled
/// by opacity/hit-testing.
private struct ForgeRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var installer: InstallController
    @EnvironmentObject private var repositories: RepositoryStore
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue
    @State private var tab = 0

    private var theme: ForgeTheme { colorScheme == .dark ? .dark : .light }

    private struct TabSpec {
        let icon: String
        /// App Store-style filled counterpart shown only while the tab is
        /// active; falls back to `icon` for symbols with no `.fill` variant.
        let filledIcon: String
        let english: String
        let arabic: String
    }

    private static let tabs: [TabSpec] = [
        TabSpec(icon: "house", filledIcon: "house.fill", english: "Home", arabic: "الرئيسية"),
        TabSpec(icon: "square.grid.2x2", filledIcon: "square.grid.2x2.fill", english: "Apps", arabic: "التطبيقات"),
        TabSpec(icon: "signature", filledIcon: "signature", english: "Sign", arabic: "توقيع"),
        TabSpec(icon: "globe", filledIcon: "globe", english: "General", arabic: "عام"),
        TabSpec(icon: "info.circle", filledIcon: "info.circle.fill", english: "About", arabic: "حول")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                HomeView()
                    .opacity(tab == 0 ? 1 : 0)
                    .allowsHitTesting(tab == 0)
                    .accessibilityHidden(tab != 0)
                AppsView()
                    .opacity(tab == 1 ? 1 : 0)
                    .allowsHitTesting(tab == 1)
                    .accessibilityHidden(tab != 1)
                ContentView()
                    .opacity(tab == 2 ? 1 : 0)
                    .allowsHitTesting(tab == 2)
                    .accessibilityHidden(tab != 2)
                GeneralView()
                    .opacity(tab == 3 ? 1 : 0)
                    .allowsHitTesting(tab == 3)
                    .accessibilityHidden(tab != 3)
                AboutView()
                    .opacity(tab == 4 ? 1 : 0)
                    .allowsHitTesting(tab == 4)
                    .accessibilityHidden(tab != 4)
            }
            // Screens cross-fade into each other instead of cutting instantly.
            .animation(.easeInOut(duration: 0.22), value: tab)
            // Reserves the floating bar's height plus its outer padding, so
            // scroll content comes to rest above the glass instead of ending
            // up trapped behind it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 64)
            }

            tabBar
        }
        .tint(theme.accent)
        .forgeTheme(theme)
        .forgeScaledType()
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs.indices, id: \.self) { index in
                tabButton(index)
            }
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        // The bar is itself a Liquid Glass surface (`GlassRole.tabBar`) rather
        // than a flat material with a divider rule: it floats clear of both
        // edges so the system renders live refraction, edge light and the
        // interactive highlight against whatever scrolls underneath it.
        .glassSurface(.tabBar)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private func tabButton(_ index: Int) -> some View {
        let spec = Self.tabs[index]
        let isActive = tab == index
        let title = languageCode == AppLanguage.arabic.rawValue ? spec.arabic : spec.english
        return Button {
            if tab != index {
                let haptic = UIImpactFeedbackGenerator(style: .light)
                haptic.prepare()
                haptic.impactOccurred()
                // A springy overshoot on the icon plus the outer cross-fade
                // is what gives switching tabs the App Store's bouncy feel.
                withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) {
                    tab = index
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isActive ? spec.filledIcon : spec.icon)
                    .font(.system(size: 21, weight: isActive ? .semibold : .regular))
                    .frame(height: 22)
                    .scaleEffect(isActive ? 1.1 : 1.0)
                Text(title)
                    // Five tabs instead of four leaves each one narrower, so
                    // the longest Arabic label ("التطبيقات") needs the smaller
                    // size and a scale-down rather than truncating.
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundColor(isActive ? theme.accent : theme.ink3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
