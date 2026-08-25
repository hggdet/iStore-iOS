import SwiftUI
import UIKit
/// Apps tab — a compact storefront for apps discovered from connected sources.
struct AppsView: View {
    @EnvironmentObject private var repositories: RepositoryStore
    @Environment(\.forgeTheme) private var T
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var selectedApp: RepoApp?
    @State private var searchText = ""
    /// `searchText` after the keystroke debounce below. Filtering reads this
    /// so typing never re-scans the whole catalog on every character.
    @State private var searchQuery = ""
    @State private var lastRefresh: Date?
    @State private var selectedCategory: String?
    @FocusState private var searchFieldFocused: Bool

    /// How long a fetched catalog is treated as current. The API caches each
    /// built page for two minutes (`PAGED_TTL`), so re-fetching sooner returns
    /// the identical payload and only costs bandwidth — matching that window
    /// means coming back to the app is the slowest an admin-panel edit can
    /// take to appear, without ever hammering the server.
    private static let freshnessWindow: TimeInterval = 120

    /// How many rows are revealed at a time. Keeps a big catalog from
    /// dumping thousands of rows into the list the instant a fetch
    /// completes — it reveals in App Store-sized batches as you scroll.
    private static let pageSize = 25
    @State private var visibleCount = pageSize

    /// Called as rows scroll into view; grows the visible window one page
    /// early (a few rows before the end) so the next batch is ready before
    /// the user hits the bottom.
    private func loadMoreIfNeeded(index: Int, of total: Int) {
        guard visibleCount < total, index >= min(visibleCount, total) - 5 else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            visibleCount = min(visibleCount + Self.pageSize, total)
        }
    }

    private var allApps: [RepoApp] {
        repositories.repositories.flatMap { repo in
            repositories.catalog[repo.id]?.apps ?? []
        }
    }

    /// The category strip, taken straight from the admin panel: the API has
    /// already dropped hidden categories, applied every rename, and sorted by
    /// `CategoryOverride.order`, so the panel alone decides what appears here
    /// and in what order — including custom categories, which carry no apps
    /// in the flat catalog and could never be derived from it.
    ///
    /// Deriving the strip from the loaded apps is kept only as an offline
    /// fallback, for a first launch that has a cached catalog but never got
    /// the category list.
    private var categories: [RepoCategory] {
        if !repositories.categories.isEmpty { return repositories.categories }
        var seen = Set<String>()
        var present: [RepoCategory] = []
        for app in allApps {
            guard let category = app.category?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !category.isEmpty, seen.insert(category).inserted else { continue }
            present.append(RepoCategory(originalName: category, displayName: category, iconURL: nil))
        }
        return present
    }

    /// True while the store catalog (or, with a category selected, that
    /// category's own admin-ordered list) is being fetched and nothing has
    /// loaded yet.
    private var isLoadingCatalog: Bool {
        if let selectedCategory {
            // No cached list and no recorded failure means the fetch is
            // running, or starts on the next runloop. Either way the tab is
            // loading — it must never claim the category has no apps. A
            // category that really is empty caches an empty array, which is
            // not `nil`, so it still falls through to the empty state.
            return repositories.categoryApps[selectedCategory] == nil
                && repositories.categoryAppsError[selectedCategory] == nil
        }
        return repositories.loadingRepoID != nil && allApps.isEmpty
    }

    /// The most recent fetch failure, if nothing loaded for the active view.
    private var catalogErrorMessage: String? {
        if let selectedCategory {
            guard repositories.categoryApps[selectedCategory] == nil else { return nil }
            return repositories.categoryAppsError[selectedCategory]
        }
        guard allApps.isEmpty else { return nil }
        return repositories.repositories.compactMap { repositories.fetchError[$0.id] }.first
    }

    /// The list on screen, derived straight from the store: a selected
    /// category shows its own admin-ordered list (fetched on demand), while
    /// "All" is the full catalog, already newest-first.
    ///
    /// Deliberately computed rather than mirrored into `@State`. The mirror
    /// only refilled at a handful of call sites, so any path that populated
    /// `categoryApps` outside them — a fetch landing after its view task was
    /// cancelled, a catalog refresh dropping the cached lists — left the tab
    /// showing an empty category until the user pulled to refresh.
    private var displayedApps: [RepoApp] {
        let apps = selectedCategory.map { repositories.categoryApps[$0] ?? [] } ?? allApps
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter { app in
            app.name.localizedCaseInsensitiveContains(query) ||
            (app.developerName?.localizedCaseInsensitiveContains(query) ?? false) ||
            (app.localizedDescription?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Non-nil while the selected category still has no list cached. Keying
    /// the fetch to this rather than to the selection alone also restarts it
    /// when the cache is dropped underneath the view — which is exactly what
    /// a successful catalog refresh does to every per-category list.
    private var pendingCategory: String? {
        guard let selectedCategory,
              repositories.categoryApps[selectedCategory] == nil else { return nil }
        return selectedCategory
    }

    var body: some View {
        let apps = displayedApps
        let visibleApps = Array(apps.prefix(visibleCount))
        return NavigationStack {
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        // Title, search and the promo strip scroll away; only
                        // the category chips pin. Keeping all of it pinned the
                        // way it used to be would nail a 2:1 banner — 179pt on
                        // a 390pt-wide screen — to the top of every scroll.
                        titleHeader
                        searchBar
                            .padding(.horizontal, T.pad)
                            .padding(.vertical, 8)
                        if !repositories.banners.isEmpty {
                            bannerStrip
                                .padding(.bottom, 12)
                        }

                        Section {
                            if apps.isEmpty {
                                if isLoadingCatalog {
                                    loadingState
                                } else if let catalogErrorMessage {
                                    errorState(catalogErrorMessage)
                                } else {
                                    emptyState
                                }
                            } else {
                                // Do not nest a LazyVStack inside the section's
                                // lazy container: nested lazy layout can preserve
                                // stale row positions while filtering.
                                ForEach(visibleApps.indices, id: \.self) { index in
                                    appRow(visibleApps[index])
                                        .padding(.horizontal, T.pad)
                                        .padding(.bottom, 12)
                                        .transaction { transaction in
                                            transaction.animation = nil
                                        }
                                        .onAppear { loadMoreIfNeeded(index: index, of: apps.count) }
                                }
                            }
                        } header: {
                            VStack(spacing: 0) {
                                if !categories.isEmpty {
                                    categorySlider
                                        .padding(.top, 4)
                                        .padding(.bottom, 10)
                                }
                            }
                            .background(T.bg.opacity(T.isDark ? 0.90 : 0.94))
                            .zIndex(2)
                        }
                    }
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [
                            T.bg.opacity(0.98),
                            T.bg.opacity(0.72),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 92)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                }
                .task {
                    await refreshIfStale()
                }
                // Returning to the app re-reads the catalog once its freshness
                // window has lapsed. Without this the store was fetched exactly
                // once per launch, so an app edited in the admin panel stayed
                // invisible until the user force-quit iStore.
                .onChange(of: scenePhase) { phase in
                    guard phase == .active else { return }
                    Task { await refreshIfStale() }
                }
                .refreshable {
                    await refreshIfStale(force: true)
                }
                .task(id: searchText) {
                    do {
                        try await Task.sleep(nanoseconds: 120_000_000)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    searchQuery = searchText
                }
                .task(id: pendingCategory) {
                    guard let pendingCategory else { return }
                    await repositories.loadCategoryApps(pendingCategory)
                }
                // A new base list starts back at one page — never carry a
                // scroll-grown window over onto content the user has not
                // scrolled to yet.
                .onChange(of: selectedCategory) { _ in
                    visibleCount = Self.pageSize
                }
                .onChange(of: searchQuery) { _ in
                    visibleCount = Self.pageSize
                }
            }
            .contentShape(Rectangle())
            .sheet(item: $selectedApp) { app in
                RepoAppDetailSheet(app: app)
            }
            .alert(
                languageCode == AppLanguage.arabic.rawValue ? "تعذر تثبيت التطبيق" : "App Installation Failed",
                isPresented: Binding(
                    get: { repositories.downloadError != nil || repositories.installError != nil },
                    set: { isPresented in
                        if !isPresented {
                            repositories.downloadError = nil
                            repositories.installError = nil
                        }
                    }
                )
            ) {
                Button(languageCode == AppLanguage.arabic.rawValue ? "حسناً" : "OK", role: .cancel) {
                    repositories.downloadError = nil
                    repositories.installError = nil
                }
            } message: {
                Text(repositories.downloadError ?? repositories.installError ?? "")
            }
        }
    }

    /// Re-reads the catalog when it has gone stale, or unconditionally when
    /// the user pulled to refresh.
    ///
    /// The selected category is re-read explicitly, and must be. Relying on
    /// `pendingCategory` alone was wrong: it only fires when the cached list
    /// goes from present to absent, so a category whose fetch had *failed*
    /// had nothing to drop, kept the same key, and never re-fetched — pull to
    /// refresh, the obvious thing to try, did nothing at all and only
    /// relaunching the app cleared it. This call is safe next to the view's
    /// own task because `fetchCategoryApps` joins a fetch already in flight
    /// instead of starting a second one.
    private func refreshIfStale(force: Bool = false) async {
        if !force, let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < Self.freshnessWindow {
            return
        }
        await refreshAll()
        lastRefresh = .now
        repositories.invalidateCategoryApps(keeping: selectedCategory)
        if let selectedCategory {
            await repositories.refreshCategoryApps(selectedCategory)
        }
    }

    private func refreshAll() async {
        let repos = repositories.repositories
        await withTaskGroup(of: Void.self) { group in
            for repo in repos {
                group.addTask {
                    await repositories.refresh(repo)
                }
            }
        }
    }

    private var titleHeader: some View {
        let isArabic = languageCode == AppLanguage.arabic.rawValue
        return Text(isArabic ? "التطبيقات" : "Apps")
            .font(T.sans(32, .bold))
            .foregroundColor(T.ink)
            // Use the selected language as the source of truth. The parent
            // layout direction can be LTR while the app language is Arabic.
            .frame(maxWidth: .infinity, alignment: isArabic ? .trailing : .leading)
            .padding(.horizontal, T.pad)
            .padding(.top, 24)
            .padding(.bottom, 16)
            // Soft App Store-style separation: a blurred fade keeps the pinned
            // title readable without creating a hard horizontal edge above search.
            .background {
                LinearGradient(
                    colors: [
                        T.bg.opacity(T.isDark ? 0.96 : 0.92),
                        T.bg.opacity(T.isDark ? 0.68 : 0.56),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blur(radius: 14)
                .padding(.horizontal, -22)
                .padding(.top, -12)
                .padding(.bottom, -8)
                .allowsHitTesting(false)
            }
            // Keep the title's physical placement stable: Arabic text remains
            // Arabic, while trailing maps to the right edge of the screen.
            .environment(\.layoutDirection, .leftToRight)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            if languageCode == AppLanguage.arabic.rawValue {
                searchField
                searchIcon
            } else {
                searchIcon
                searchField
            }
        }
        // Keep the explicit semantic order above from being mirrored a second time.
        .environment(\.layoutDirection, .leftToRight)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .fMilkGlass(
            in: RoundedRectangle(cornerRadius: 14, style: .continuous),
            interactive: true
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: languageCode)
    }

    /// Promo banners from the panel, above the category chips. A single
    /// banner renders as one card; several become a swipeable pager with the
    /// page dots the system draws. Height is derived from the 2:1 artwork the
    /// panel produces so the card never letterboxes.
    private var bannerStrip: some View {
        let banners = repositories.banners
        return Group {
            if banners.count == 1, let only = banners.first {
                bannerCard(only)
            } else {
                TabView {
                    ForEach(banners) { banner in
                        bannerCard(banner)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .frame(height: bannerHeight + 28)
            }
        }
        .padding(.horizontal, T.pad)
    }

    /// 2:1 artwork, inset by the page padding on both sides.
    private var bannerHeight: CGFloat {
        (UIScreen.main.bounds.width - T.pad * 2) / 2
    }

    private func bannerCard(_ banner: RepoBanner) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button {
            guard let link = banner.linkURL else { return }
            openURL(link)
        } label: {
            AsyncImage(url: banner.imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    // A dead image URL must not leave a blank slab behind.
                    Color.clear
                default:
                    Color.white.opacity(0.05).shimmer()
                }
            }
            .frame(height: bannerHeight)
            .frame(maxWidth: .infinity)
            .clipShape(shape)
            .overlay {
                shape.stroke(T.rule, lineWidth: AppStroke.hairline)
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(banner.linkURL == nil)
    }

    private var categorySlider: some View {
        let isArabic = languageCode == AppLanguage.arabic.rawValue
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryChip(
                    title: isArabic ? "الكل" : "All",
                    iconURL: nil,
                    isSelected: selectedCategory == nil
                ) {
                    selectCategory(nil)
                }
                ForEach(categories) { category in
                    categoryChip(
                        title: category.displayName,
                        iconURL: category.iconURL,
                        isSelected: selectedCategory == category.originalName
                    ) {
                        selectCategory(
                            selectedCategory == category.originalName ? nil : category.originalName
                        )
                    }
                }
            }
            .padding(.horizontal, T.pad)
        }
        // Chips always read start-to-end in the language's own direction,
        // independent of each label's own script (emoji + Arabic text).
        .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
    }

    private func selectCategory(_ category: String?) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            selectedCategory = category
        }
    }

    private func categoryChip(title: String,
                              iconURL: URL?,
                              isSelected: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Only categories the panel gave an icon draw one; the rest
                // keep the plain text chip they have always had.
                if let iconURL {
                    AsyncImage(url: iconURL) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 16, height: 16)
                }
                Text(title)
            }
            .font(T.sans(13, .semibold))
            .foregroundColor(isSelected ? (T.isDark ? .black : .white) : T.ink)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background {
                if isSelected {
                    Capsule()
                        .fill(T.isDark ? Color.white : Color.black)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .fClearGlass(in: Capsule(), interactive: true)
            .scaleEffect(isSelected ? 1.04 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private var searchIcon: some View {
        Button {
            searchFieldFocused = false
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(T.isDark ? .white : .black)
                .frame(width: 30, height: 30, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        let isArabic = languageCode == AppLanguage.arabic.rawValue
        let textAlignment: TextAlignment = isArabic ? .trailing : .leading
        let frameAlignment: Alignment = isArabic ? .trailing : .leading
        let placeholder = isArabic ? "ألعاب وتطبيقات والمزيد" : "Games, apps and more"

        return ZStack(alignment: frameAlignment) {
            if searchText.isEmpty {
                Text(placeholder)
                    .font(T.sans(15, .bold))
                    .foregroundColor(T.isDark ? .white.opacity(0.48) : .black.opacity(0.28))
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                    .allowsHitTesting(false)
            }

            TextField("", text: $searchText)
                .textFieldStyle(.plain)
                .font(T.sans(15, .bold))
                .foregroundColor(T.isDark ? .white : .black)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($searchFieldFocused)
                .onSubmit { searchFieldFocused = false }
        }
        .environment(\.layoutDirection, .leftToRight)
        .layoutPriority(1)
    }

    private var emptyState: some View {
        VStack(spacing: T.gap) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text(languageCode == AppLanguage.arabic.rawValue ? "لا توجد تطبيقات بعد" : "No apps yet")
                .font(T.sans(15, .medium))
                .foregroundColor(T.ink)
            MonoText(text: languageCode == AppLanguage.arabic.rawValue ? "لم يرسل المتجر أي تطبيقات حالياً." : "The store didn't return any apps right now.", size: 10, color: T.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, T.pad)
        .fGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private var loadingState: some View {
        VStack(spacing: T.gap) {
            ProgressView()
                .tint(T.ink3)
            Text(languageCode == AppLanguage.arabic.rawValue ? "جارِ تحميل المتجر…" : "Loading the store…")
                .font(T.sans(15, .medium))
                .foregroundColor(T.ink)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, T.pad)
        .fGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: T.gap) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text(languageCode == AppLanguage.arabic.rawValue ? "تعذر تحميل المتجر" : "Couldn't load the store")
                .font(T.sans(15, .medium))
                .foregroundColor(T.ink)
            MonoText(text: message, size: 10, color: T.ink3)
            Button {
                Task {
                    if let selectedCategory {
                        await repositories.refreshCategoryApps(selectedCategory)
                    } else {
                        await refreshAll()
                    }
                }
            } label: {
                Text(languageCode == AppLanguage.arabic.rawValue ? "إعادة المحاولة" : "Retry")
                    .font(T.sans(13, .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(T.accent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, T.pad)
        .fGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private func appRow(_ app: RepoApp) -> some View {
        HStack(spacing: 12) {
            Button {
                selectedApp = app
            } label: {
                HStack(spacing: 12) {
                    CachedAppIcon(url: app.iconURL, size: 44, cornerRadius: 11)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(app.name)
                            .font(T.sans(15, .medium))
                            .foregroundColor(T.ink)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            getButton(app)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .glassSurface(.card, cornerRadius: 18)
        .modifier(RowRevealAnimation())
    }

    private func getButton(_ app: RepoApp) -> some View {
        let isLoading = repositories.activeInstallID == app.id
        return GlassGetButton(
            isLoading: isLoading,
            isInstalled: false,
            disabled: app.downloadURL == nil ||
                (repositories.activeInstallID != nil && repositories.activeInstallID != app.id)
        ) {
            if repositories.activeInstallID == app.id {
                repositories.cancelInstallAttempt(app.id)
            } else {
                // The primary button always means a normal installation. The
                // explicit second-copy action lives in the detail sheet so a stale
                // local record can never change this button's meaning.
                repositories.clearInstalled(app.id)
                Task { await repositories.download(app) }
            }
        }
    }
}

/// Fades + settles a row in the moment it first scrolls on screen, instead
/// of it popping in fully-formed. Keyed to this view instance, so it fires
/// once per row and stays out of the way of `appRow`'s own transaction
/// (which intentionally suppresses animation on filter/category swaps).
private struct RowRevealAnimation: ViewModifier {
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3)) {
                    appeared = true
                }
            }
    }
}
