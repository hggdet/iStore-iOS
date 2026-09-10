import SwiftUI

/// Shows applications installed through the repository storefront and compares
/// their recorded version with the latest version in the refreshed catalogs.
struct UpdatesSheet: View {
    @EnvironmentObject private var repositories: RepositoryStore
    @Environment(\.forgeTheme) private var T
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    private var installedApps: [RepoApp] {
        var seen = Set<String>()
        return repositories.repositories
            .flatMap { repositories.catalog[$0.id]?.apps ?? [] }
            .filter { repositories.installedAppIDs.contains($0.id) && seen.insert($0.id).inserted }
    }

    private var updates: [RepoApp] {
        installedApps.filter { repositories.isUpdateAvailable(for: $0) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 12) {
                        if installedApps.isEmpty {
                            emptyState(
                                title: languageCode == AppLanguage.arabic.rawValue ? "لا توجد تطبيقات مثبتة" : "No installed apps",
                                message: languageCode == AppLanguage.arabic.rawValue
                                    ? "نزّل تطبيقاً من المتجر حتى يظهر هنا."
                                    : "Apps downloaded from the store will appear here."
                            )
                        } else {
                            if !updates.isEmpty {
                                Text(languageCode == AppLanguage.arabic.rawValue ? "تحديثات متاحة" : "Updates available")
                                    .font(T.sans(14, .semibold))
                                    .foregroundColor(T.accent)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(installedApps) { app in
                                updateRow(app)
                            }
                        }
                    }
                    .padding(.horizontal, T.pad)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
                .background { ForgeBackdrop() }
            }
            .navigationTitle(languageCode == AppLanguage.arabic.rawValue ? "التحديثات" : "Updates")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await refreshAll()
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

    private func updateRow(_ app: RepoApp) -> some View {
        let isLoading = repositories.activeInstallID == app.id
        let installedVersion = repositories.installedVersions[app.id] ?? "—"
        let latestVersion = app.version ?? "—"

        return HStack(spacing: 12) {
            CachedAppIcon(url: app.iconURL, size: 46, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(T.sans(15, .semibold))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                Text("\(installedVersion)  →  \(latestVersion)")
                    .font(T.mono(10))
                    .foregroundColor(T.ink3)
            }
            Spacer(minLength: 8)
            if repositories.isUpdateAvailable(for: app) {
                Button {
                    Task { await repositories.download(app) }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView()
                                .tint(T.accent)
                        } else {
                            Text(languageCode == AppLanguage.arabic.rawValue ? "تحديث" : "Update")
                                .font(T.sans(12, .bold))
                                .foregroundColor(T.accent)
                        }
                    }
                    .frame(minWidth: 62, minHeight: 34)
                    .background(T.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isLoading || (repositories.activeInstallID != nil && !isLoading))
            } else {
                Text(languageCode == AppLanguage.arabic.rawValue ? "محدث" : "Up to date")
                    .font(T.sans(11, .medium))
                    .foregroundColor(T.good)
            }
        }
        .padding(12)
        .glassSurface(.card, cornerRadius: 18)
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle")
                .font(.system(size: 28))
                .foregroundColor(T.ink3)
            Text(title)
                .font(T.sans(16, .semibold))
                .foregroundColor(T.ink)
            Text(message)
                .font(T.sans(12))
                .foregroundColor(T.ink3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}
