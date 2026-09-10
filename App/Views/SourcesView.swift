import SwiftUI
import UIKit

/// Sources tab — add AltStore-style repository URLs, browse their apps, and
/// download an IPA. A finished download is handed to the Sign tab (via
/// `RepositoryStore.pendingIPA`) so the user signs + installs exactly as today.
struct SourcesView: View {
    @EnvironmentObject private var store: RepositoryStore
    @Environment(\.forgeTheme) private var T
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @State private var newRepoURL = ""
    @State private var addError: String?
    @State private var selectedRepo: Repository?
    @State private var repoPendingDeletion: Repository?
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        addSection
                        if let addError {
                            Text(addError)
                                .font(T.mono(10))
                                .foregroundColor(T.bad)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, T.pad)
                                .padding(.top, 12)
                        }
                        reposSection
                    }
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .navigationTitle("Sources")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(item: $selectedRepo) { repo in
                    RepoDetailSheet(repo: repo)
                }
                .alert(
                    "Delete source?",
                    isPresented: $showDeleteConfirmation
                ) {
                    Button("Cancel", role: .cancel) {
                        repoPendingDeletion = nil
                    }
                    Button("Delete", role: .destructive) {
                        if let repoPendingDeletion {
                            store.remove(repoPendingDeletion)
                        }
                        self.repoPendingDeletion = nil
                    }
                } message: {
                    Text("This source and its cached apps will be removed from the store.")
                }
            }
        }
        .floatingGlassBackButton(action: { dismiss() })
    }

    private var addSection: some View {
        VStack(spacing: 0) {
            GlassSection("Add Repository") {
                GlassInputRow(icon: "link", label: "URL",
                              placeholder: "https://…/repos.json", text: $newRepoURL)
            }
            GlassPrimaryButton(label: "Save Source", systemImage: "square.and.arrow.down",
                               action: add,
                               disabled: newRepoURL.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, T.pad)
                .padding(.top, 16)
        }
    }

    @ViewBuilder
    private var reposSection: some View {
        if store.repositories.isEmpty {
            emptyState
        } else {
            GlassSection("Repositories") {
                VStack(spacing: 0) {
                    ForEach(Array(store.repositories.enumerated()), id: \.element.id) { index, repo in
                        repoRow(repo)
                        if index < store.repositories.count - 1 {
                            GlassRowDivider()
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: T.gap) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text("No repositories yet")
                .font(T.sans(15))
                .foregroundColor(T.ink)
            MonoText(text: "Add a source URL to browse and download apps.", size: 10, color: T.ink3)
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

        private func repoRow(_ repo: Repository) -> some View {
        HStack(spacing: 10) {
            Button {
                selectedRepo = repo
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(T.accent2)
                        .frame(width: 38, height: 38)
                        .fClearGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repo.name)
                            .font(T.sans(15, .medium))
                            .foregroundColor(T.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(repo.url.host ?? repo.url.absoluteString)
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let count = store.catalog[repo.id]?.apps.count {
                        GlassStatusPill(text: "\(count) apps", color: T.accent)
                    }
                    if repo.url.scheme?.lowercased() == "http" {
                        GlassStatusPill(text: "HTTP", color: T.warn)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(GlassTactileButtonStyle())

            Button {
                repoPendingDeletion = repo
                showDeleteConfirmation = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .bold))
                    Text(LocalizedStringKey("Delete"))
                        .font(T.mono(9, .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .foregroundColor(T.bad)
                .frame(width: 82, height: 36)
                .fClearGlass(in: Capsule(), interactive: true)
            }
            .buttonStyle(GlassTactileButtonStyle())
            .accessibilityLabel(LocalizedStringKey("Delete"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }


    private func add() {
        switch store.add(urlString: newRepoURL) {
        case .success(let repo):
            newRepoURL = ""
            addError = nil
            Task { await store.refresh(repo) }
        case .failure(let failure):
            addError = failure.errorDescription
        }
    }
}

// MARK: - Repo detail (apps list)

/// Sheet listing one repository's apps with a per-app download ("Get") action.
struct RepoDetailSheet: View {
    let repo: Repository

    @EnvironmentObject private var store: RepositoryStore
    @Environment(\.forgeTheme) private var T
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @State private var selectedApp: RepoApp?

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        content
                    }
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .navigationTitle(repo.name)
                .navigationBarTitleDisplayMode(.inline)
                .refreshable { await store.refresh(repo) }
                .sheet(item: $selectedApp) { app in
                    RepoAppDetailSheet(app: app)
                }
            }
        }
        .floatingGlassBackButton(action: { dismiss() })
        .presentationDetents([.large])
        .task { if store.catalog[repo.id] == nil { await store.refresh(repo) } }
    }

    @ViewBuilder
    private var content: some View {
        if let source = store.catalog[repo.id] {
            if source.apps.isEmpty {
                message(icon: "tray", "This source has no apps.")
            } else {
                GlassSection("Apps") {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(source.apps.enumerated()), id: \.element.id) { index, app in
                            appRow(app)
                            if index < source.apps.count - 1 {
                                GlassRowDivider()
                            }
                        }
                    }
                }
                if let downloadError = store.downloadError {
                    Text(downloadError)
                        .font(T.mono(10))
                        .foregroundColor(T.bad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, T.pad)
                        .padding(.top, 12)
                }
            }
        } else if store.loadingRepoID == repo.id {
            loadingState
        } else if let error = store.fetchError[repo.id] {
            message(icon: "exclamationmark.triangle", error)
        }
    }

    private var loadingState: some View {
        VStack(spacing: T.gap) {
            ProgressView().tint(T.accent)
            MonoText(text: "Loading repository…", size: 10, color: T.ink3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.top, 24)
    }

    private func message(icon: String, _ text: String) -> some View {
        VStack(spacing: T.gap) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text(text)
                .font(T.mono(11))
                .foregroundColor(T.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
            appIcon(app)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(T.sans(15, .medium))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let version = app.version {
                        Text("v\(version)").font(T.mono(10)).foregroundColor(T.ink3)
                    }
                    if let size = app.size {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(T.mono(10)).foregroundColor(T.ink3)
                    }
                    if let dev = app.developerName {
                        Text(dev).font(T.mono(10)).foregroundColor(T.ink4)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    if app.versions.count > 1 {
                        Text("\(app.versions.count) versions")
                            .font(T.mono(9))
                            .foregroundColor(T.accent2)
                    }
                    if let description = app.localizedDescription, !description.isEmpty {
                        Text(description)
                            .font(T.mono(9))
                            .foregroundColor(T.ink4)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            Spacer(minLength: 8)

            Button {
                selectedApp = app
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(T.ink3)
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(GlassTactileButtonStyle())

            getButton(app)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func appIcon(_ app: RepoApp) -> some View {
        CachedAppIcon(url: app.iconURL, size: 38, cornerRadius: 10)
    }

    @ViewBuilder
    private func getButton(_ app: RepoApp) -> some View {
        if store.activeDownloadID == app.id {
            ProgressView().tint(T.accent).frame(width: 52)
        } else {
            Button {
                Task { await store.download(app) }
            } label: {
                Text("GET")
                    .font(T.mono(11, .semibold))
                    .foregroundColor(app.downloadURL == nil ? T.ink4 : T.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .overlay {
                        Capsule().stroke((app.downloadURL == nil ? T.ink4 : T.accent).opacity(0.4),
                                         lineWidth: AppStroke.hairline)
                    }
            }
            .buttonStyle(GlassTactileButtonStyle())
            .disabled(app.downloadURL == nil || store.activeDownloadID != nil)
        }
    }
}

/// Detail inspector for a source app. Normal GET and the explicit second-copy
/// action are kept separate so each button has one predictable meaning.
struct RepoAppDetailSheet: View {
    let app: RepoApp

    @EnvironmentObject private var store: RepositoryStore
    @Environment(\.forgeTheme) private var T
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @State private var isDownloading = false
    @State private var isRepeating = false
    @State private var showReinstallConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                ForgeBackdrop()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        hero
                        appSummary
                        if !app.screenshotURLs.isEmpty {
                            screenshotsSection
                        }
                        shortDivider
                        infoPills
                    }
                    // Keep the hero card below the floating back control so the
                    // sheet canvas remains visible at the top on every app.
                    .padding(.top, 76)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }
        }
        .floatingGlassBackButton(action: { dismiss() })
        // A compact detail layout avoids an oversized empty tail below the info cards.
        .presentationDetents([.height(620)])
        .presentationCornerRadius(34)
        .presentationDragIndicator(.hidden)
        .presentationBackground { ForgeBackdrop() }
        .alert(
            languageCode == AppLanguage.arabic.rawValue ? "تكرار التطبيق" : "Repeat app",
            isPresented: $showReinstallConfirmation
        ) {
            Button(languageCode == AppLanguage.arabic.rawValue ? "تكرار" : "Repeat") {
                startDownload(asAdditionalCopy: true)
            }
            Button(languageCode == AppLanguage.arabic.rawValue ? "إلغاء" : "Cancel", role: .cancel) {}
        } message: {
            Text(languageCode == AppLanguage.arabic.rawValue
                 ? "سيتم إنشاء نسخة مستقلة جديدة بمعرّف مختلف عن التطبيق الأصلي. يمكنك تكرارها أكثر من مرة."
                 : "A new independent copy with a different bundle identifier will be created. You can repeat it multiple times.")
        }
    }

    private var hero: some View {
        ZStack {
            Color.black.opacity(T.isDark ? 0.92 : 0.84)

            AsyncImage(url: app.iconURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color.gray.opacity(0.25)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .blur(radius: 24)
            .scaleEffect(1.15)
            .overlay(Color.black.opacity(0.22))
            .clipped()

            LinearGradient(
                colors: [.black.opacity(0.05), .black.opacity(0.52)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxWidth: .infinity)
            .frame(height: 340)

            VStack(spacing: 12) {
                appIcon

                Text(app.name.isEmpty ? "Untitled" : app.name)
                    .font(T.sans(23, .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    getButton
                    repeatButton
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, T.pad)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(T.isDark ? 0.10 : 0.32), lineWidth: AppStroke.hairline)
                .allowsHitTesting(false)
        }
        // Float the blurred art as its own card rather than letting it reach
        // the sheet edges, keeping the surrounding glass canvas visible.
        .padding(.horizontal, T.pad)
    }

    private var appSummary: some View {
        EmptyView()
    }

    private var shortDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.10))
            .frame(width: 130, height: 1)
            .padding(.vertical, 22)
    }

    private var infoPills: some View {
        HStack(alignment: .center, spacing: 12) {
            infoPill(title: localized("Version", "الإصدار"), value: localizedDigits(app.version ?? "—"))
            infoPill(title: localized("App Size", "حجم التطبيق"), value: localizedSizeValue)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, T.pad + 20)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var localizedSizeValue: String {
        guard let size = app.size else { return "—" }
        let megabytes = Double(size) / 1_000_000
        let formatted = String(
            format: "%.1f",
            locale: Locale(identifier: "en_US_POSIX"),
            megabytes
        )
        return localizedDigits(formatted)
    }

    private func localized(_ english: String, _ arabic: String) -> String {
        languageCode == AppLanguage.arabic.rawValue ? arabic : english
    }

    private func localizedDigits(_ value: String) -> String {
        guard languageCode == AppLanguage.arabic.rawValue else { return value }
        let western = Array("0123456789")
        let eastern = Array("٠١٢٣٤٥٦٧٨٩")
        return String(value.map { character in
            guard let index = western.firstIndex(of: character) else { return character }
            return eastern[western.distance(from: western.startIndex, to: index)]
        })
    }

    private var screenshotsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(app.screenshotURLs.enumerated()), id: \.offset) { _, url in
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            case .failure:
                                Color.gray.opacity(0.18)
                                    .overlay {
                                        Image(systemName: "photo")
                                            .foregroundColor(T.ink3)
                                    }
                            case .empty:
                                ProgressView()
                                    .tint(T.ink3)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Color.gray.opacity(0.12))
                            @unknown default:
                                Color.gray.opacity(0.18)
                            }
                        }
                        .frame(width: 220, height: 390)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(T.rule, lineWidth: AppStroke.hairline)
                        }
                    }
                }
                .padding(.horizontal, T.pad)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 30)
    }

    private var getButton: some View {
        let isInstalling = isDownloading || store.activeInstallID == app.id
        return GlassGetButton(
            isLoading: isInstalling && !isRepeating,
            isInstalled: false,
            disabled: app.downloadURL == nil ||
                (store.activeInstallID != nil && store.activeInstallID != app.id),
            emphasizesText: true
        ) {
            if store.activeInstallID == app.id {
                store.cancelInstallAttempt(app.id)
                isDownloading = false
                isRepeating = false
            } else {
                // GET always means a normal installation. The second-copy path is
                // intentionally available only through the explicit button below.
                store.clearInstalled(app.id)
                startDownload()
            }
        }
    }

    private var repeatButton: some View {
        Button {
            guard !isDownloading, store.activeInstallID == nil else { return }
            ForgeInteractionFeedback.playLightHaptic()
            ForgeInteractionFeedback.playPressSound()
            showReinstallConfirmation = true
        } label: {
            Group {
                if isRepeating {
                    InstallLoadingAnimation(color: repeatGreen)
                } else {
                    Text(localized("Repeat", "تكرار"))
                        .font(T.sans(12.5, .heavy))
                }
            }
            .foregroundColor(.white)
            .frame(width: 76, height: 34)
            .background {
                Capsule()
                    .fill(repeatGreen.opacity(T.isDark ? 0.20 : 0.12))
            }
        }
        .buttonStyle(GlassTactileButtonStyle())
        .fPrimaryActionGlass(in: Capsule())
        .disabled(isDownloading || store.activeInstallID != nil)
        .opacity(isDownloading || store.activeInstallID != nil ? 0.48 : 1)
    }

    private var repeatGreen: Color {
        Color(red: 0.18, green: 0.72, blue: 0.36)
    }

    private func startDownload(asAdditionalCopy: Bool = false) {
        isDownloading = true
        isRepeating = asAdditionalCopy
        Task {
            await store.download(app, asAdditionalCopy: asAdditionalCopy)
            await MainActor.run {
                isDownloading = false
                isRepeating = false
            }
        }
    }

    private var appIcon: some View {
        AsyncImage(url: app.iconURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Image(systemName: "app.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(T.accent2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
            }
        }
        .frame(width: 94, height: 94)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.8), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.20), radius: 14, y: 8)
    }

    private func infoPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(T.sans(10, .semibold))
                .foregroundColor(T.isDark ? .white.opacity(0.72) : .black.opacity(0.62))
            Text(value)
                .font(T.sans(16, .bold))
                .foregroundColor(T.isDark ? .white : .black)
                .lineLimit(1)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .frame(height: 58, alignment: .center)
        .padding(.horizontal, 8)
        .fClearGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(T.isDark ? Color.gray.opacity(0.24) : Color.gray.opacity(0.18))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
