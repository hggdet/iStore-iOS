import SwiftUI

/// Full-screen detail sheet for a single app from the Ceresify catalog —
/// shown from `AppsView` when a row is tapped.
struct RepoAppDetailSheet: View {
    let app: RepoApp

    @EnvironmentObject private var store: RepositoryStore
    @Environment(\.forgeTheme) private var T
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @State private var isDownloading = false
    @State private var isRepeating = false
    @State private var showReinstallConfirmation = false
    @State private var showReportSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                ForgeBackdrop()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        hero
                        infoPills
                        if !app.screenshotURLs.isEmpty {
                            screenshotsSection
                        }
                        if let description = app.localizedDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !description.isEmpty {
                            shortDivider
                            descriptionSection(description)
                        }
                        reportSection
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
        // Compact by default so short apps avoid an empty tail below the info
        // cards; draggable to full height so a long description stays reachable.
        .presentationDetents([.height(620), .large])
        .presentationCornerRadius(34)
        .presentationDragIndicator(.hidden)
        .presentationBackground { ForgeBackdrop() }
        .sheet(isPresented: $showReportSheet) {
            ReportIssueSheet(app: app)
        }
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

    private var shortDivider: some View {
        Rectangle()
            .fill(Color.black.opacity(0.10))
            .frame(width: 130, height: 1)
            .padding(.vertical, 22)
    }

    private var infoPills: some View {
        HStack(alignment: .center, spacing: 12) {
            infoPill(title: localized("Version", "الإصدار"), value: localizedDigits(app.version ?? "—"))
            infoPill(title: localized("Updated", "آخر تحديث"), value: localizedUpdatedValue)
            infoPill(title: localized("App Size", "حجم التطبيق"), value: localizedSizeValue)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, T.pad + 20)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private static let updatedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed numeric, locale-neutral format — digits alone are then
        // swapped to Eastern Arabic numerals to match the rest of the sheet.
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var localizedUpdatedValue: String {
        guard let date = app.lastUpdated else { return "—" }
        return localizedDigits(Self.updatedDateFormatter.string(from: date))
    }

    private func descriptionSection(_ description: String) -> some View {
        // Match the rest of the sheet: alignment is driven explicitly by the
        // selected app language rather than the ambient layout direction.
        let isArabic = languageCode == AppLanguage.arabic.rawValue
        let alignment: Alignment = isArabic ? .trailing : .leading
        let textAlignment: TextAlignment = isArabic ? .trailing : .leading

        return VStack(alignment: isArabic ? .trailing : .leading, spacing: 10) {
            Text(localized("Description", "الوصف"))
                .font(T.sans(13, .semibold))
                .foregroundColor(T.ink3)
                .frame(maxWidth: .infinity, alignment: alignment)
            Text(description)
                .font(T.sans(14, .regular))
                .foregroundColor(T.ink)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: alignment)
                .multilineTextAlignment(textAlignment)
        }
        .padding(.horizontal, T.pad + 4)
        .padding(.bottom, 28)
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

    /// Foot of the sheet, mirroring where the App Store keeps the same control:
    /// out of the way of GET, but present on every app whether or not the
    /// catalog gave it a description.
    private var reportSection: some View {
        VStack(spacing: 0) {
            shortDivider
            Button {
                ForgeInteractionFeedback.playLightHaptic()
                showReportSheet = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.bubble")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(localized("Report", "إبلاغ"))
                        .font(T.sans(13, .semibold))
                }
                .foregroundColor(T.ink2)
                .padding(.horizontal, 18)
                .frame(height: 38)
                .fClearGlass(in: Capsule(), interactive: true)
                .background {
                    Capsule().fill(T.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
                }
                .clipShape(Capsule())
            }
            .buttonStyle(GlassTactileButtonStyle())
        }
        .padding(.bottom, 10)
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
                .minimumScaleFactor(0.6)
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
