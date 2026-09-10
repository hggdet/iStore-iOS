import SwiftUI
/// Apps tab — a compact storefront for apps discovered from connected sources.
struct AppsView: View {
    @EnvironmentObject private var repositories: RepositoryStore
    @Environment(\.forgeTheme) private var T
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @State private var selectedApp: RepoApp?
    @State private var searchText = ""
    @State private var displayedApps: [RepoApp] = []
    @State private var didInitialRefresh = false
    @FocusState private var searchFieldFocused: Bool

    private var allApps: [RepoApp] {
        repositories.repositories.flatMap { repo in
            repositories.catalog[repo.id]?.apps ?? []
        }
    }

    private func refreshDisplayedApps() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            displayedApps = allApps
            return
        }
        displayedApps = allApps.filter { app in
            app.name.localizedCaseInsensitiveContains(query) ||
            (app.developerName?.localizedCaseInsensitiveContains(query) ?? false) ||
            (app.localizedDescription?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            if displayedApps.isEmpty {
                                emptyState
                            } else {
                                // Do not nest a LazyVStack inside the section's
                                // lazy container: nested lazy layout can preserve
                                // stale row positions while filtering.
                                ForEach(displayedApps.indices, id: \.self) { index in
                                    appRow(displayedApps[index])
                                        .padding(.horizontal, T.pad)
                                        .padding(.bottom, 12)
                                        .transaction { transaction in
                                            transaction.animation = nil
                                        }
                                }
                            }
                        } header: {
                            VStack(spacing: 0) {
                                titleHeader
                                searchBar
                                    .padding(.horizontal, T.pad)
                                    .padding(.vertical, 8)
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
                    guard !didInitialRefresh else { return }
                    while !repositories.catalogCacheLoaded {
                        try? await Task.sleep(nanoseconds: 20_000_000)
                    }
                    refreshDisplayedApps()
                    didInitialRefresh = true
                    await refreshAll()
                    refreshDisplayedApps()
                }
                .refreshable {
                    await refreshAll()
                    refreshDisplayedApps()
                }
                .task(id: searchText) {
                    do {
                        try await Task.sleep(nanoseconds: 120_000_000)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    refreshDisplayedApps()
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
            MonoText(text: languageCode == AppLanguage.arabic.rawValue ? "أضف مصدراً من تبويب التوقيع لاكتشاف التطبيقات هنا." : "Add a source from the Sign tab to discover apps here.", size: 10, color: T.ink3)
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
