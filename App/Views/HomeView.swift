import SwiftUI

// MARK: - Model

struct FeaturedApp: Decodable, Identifiable, Equatable {
    let id: String
    let bundleId: String
    let name: String
    let subtitle: String?
    let note: String?
    let description: String?
    let version: String?
    let size: Int64?
    let date: Date?
    let imageURL: URL?
    let iconURL: URL?
    /// The panel's own flag for "this bundle id still resolves to a real
    /// app in the catalog". A false value is surfaced, not hidden.
    let found: Bool

    private enum CodingKeys: String, CodingKey {
        case id, bundleId, name, subtitle, note, description, version, size, date
        case imageUrl, iconUrl, found
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = (try? c.decodeIfPresent(String.self, forKey: .bundleId)) ?? ""
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? bundleId
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        version = try? c.decodeIfPresent(String.self, forKey: .version)
        size = (try? c.decodeIfPresent(Int64.self, forKey: .size)) ?? nil
        found = ((try? c.decodeIfPresent(Bool.self, forKey: .found)) ?? nil) ?? true
        if let raw = try? c.decodeIfPresent(String.self, forKey: .date) {
            date = FeaturedDateParser.fractional.date(from: raw)
                ?? FeaturedDateParser.plain.date(from: raw)
        } else {
            date = nil
        }
        imageURL = FeaturedAsset.absoluteURL(try? c.decodeIfPresent(String.self, forKey: .imageUrl))
        iconURL = FeaturedAsset.absoluteURL(try? c.decodeIfPresent(String.self, forKey: .iconUrl))
    }
}

struct FeaturedResponse: Decodable { let featured: [FeaturedApp] }

// The feed stamps dates with fractional seconds; the plain parser is the
// fallback for entries written without them.
enum FeaturedDateParser {
    nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()
}

enum FeaturedAsset {
    /// Icons come back as container-relative paths (`/uploads/icons/…`) while
    /// banners are already absolute, so both shapes have to be accepted.
    static func absoluteURL(_ raw: String?) -> URL? {
        guard let value = raw, !value.isEmpty else { return nil }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return URL(string: value)
        }
        return URL(string: RepositorySource.ceresifyBase + (value.hasPrefix("/") ? value : "/" + value))
    }
}

/// Where Ceresify's uploads and endpoints live.
enum RepositorySource {
    static let ceresifyBase = "https://dev.ceresify.com"
}

/// Home tab — the featured showcase Ceresify's own `main.html` renders, from
/// the same `/api/sign/featured` endpoint. Each entry is a wide promo card
/// (banner artwork, name, subtitle, icon) that opens a detail sheet with the
/// version/size/date stats and description, exactly like the web page.
///
/// Installing deliberately does not use the feed's own `ipaUrl`: the entry is
/// matched back to its `RepoApp` in the loaded catalog so the download runs
/// through the identical sign-and-install pipeline the Apps tab uses. An entry
/// with no match is shown with its button disabled, mirroring the web page's
/// "التطبيق غير متوفر" state.
struct HomeView: View {
    @EnvironmentObject private var repositories: RepositoryStore
    @Environment(\.forgeTheme) private var T
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @State private var featured: [FeaturedApp] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selected: FeaturedApp?
    @State private var didLoad = false

    private static let featuredURL = URL(string: RepositorySource.ceresifyBase + "/api/sign/featured")!

    private var isArabic: Bool { languageCode == AppLanguage.arabic.rawValue }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    LazyVStack(spacing: 18) {
                        header
                        content
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
                .refreshable { await load() }
                .task {
                    guard !didLoad else { return }
                    didLoad = true
                    await load()
                }
            }
            .sheet(item: $selected) { app in
                detailSheet(app)
                    .liquidGlassSheet()
            }
        }
    }

    private var header: some View {
        Text(isArabic ? "الرئيسية" : "Home")
            .font(T.sans(32, .bold))
            .foregroundColor(T.ink)
            .frame(maxWidth: .infinity, alignment: isArabic ? .trailing : .leading)
            .padding(.horizontal, T.pad)
            .environment(\.layoutDirection, .leftToRight)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && featured.isEmpty {
            stateCard {
                ProgressView().tint(T.ink3)
                Text(isArabic ? "جارِ التحميل…" : "Loading…")
                    .font(T.sans(15, .medium)).foregroundColor(T.ink)
            }
        } else if let errorMessage, featured.isEmpty {
            stateCard {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20)).foregroundColor(T.ink3)
                Text(isArabic ? "تعذر التحميل" : "Couldn't load")
                    .font(T.sans(15, .medium)).foregroundColor(T.ink)
                MonoText(text: errorMessage, size: 10, color: T.ink3)
                Button { Task { await load() } } label: {
                    Text(isArabic ? "إعادة المحاولة" : "Retry").font(T.sans(13, .semibold))
                }
                .buttonStyle(.plain).foregroundColor(T.accent).padding(.top, 4)
            }
        } else if featured.isEmpty {
            stateCard {
                Image(systemName: "star")
                    .font(.system(size: 20)).foregroundColor(T.ink3)
                Text(isArabic ? "لا توجد تطبيقات مميزة" : "Nothing featured yet")
                    .font(T.sans(15, .medium)).foregroundColor(T.ink)
            }
        } else {
            ForEach(featured) { app in
                card(app)
                    .padding(.horizontal, T.pad)
            }
        }
    }

    private func stateCard<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        VStack(spacing: T.gap) { inner() }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .padding(.horizontal, T.pad)
            .fGlass(cornerRadius: 16)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(T.rule, lineWidth: AppStroke.hairline)
            }
            .padding(.horizontal, T.pad)
            .padding(.top, 12)
    }

    // MARK: - Card

    /// Banner artwork is 2:1 like the panel produces, with the name, subtitle
    /// and icon laid over a bottom scrim — the same shape `main.html` draws.
    private var cardHeight: CGFloat {
        (UIScreen.main.bounds.width - T.pad * 2) / 2
    }

    private func card(_ app: FeaturedApp) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Button {
            selected = app
        } label: {
            ZStack(alignment: .bottom) {
                AsyncImage(url: app.imageURL) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                    case .failure: Color.white.opacity(0.04)
                    default: Color.white.opacity(0.05).shimmer()
                    }
                }
                .frame(height: cardHeight)
                .frame(maxWidth: .infinity)
                .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.35), .black.opacity(0.82)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                cardFooter(app)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            .frame(height: cardHeight)
            .clipShape(shape)
            .overlay { shape.stroke(T.rule, lineWidth: AppStroke.hairline) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }

    private func cardFooter(_ app: FeaturedApp) -> some View {
        HStack(alignment: .bottom, spacing: 12) {
            getButton(app)

            VStack(alignment: .trailing, spacing: 2) {
                Text(app.name)
                    .font(T.sans(16, .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let subtitle = app.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(T.sans(12, .medium))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            CachedAppIcon(url: app.iconURL, size: 46, cornerRadius: 12)
        }
        // The footer keeps this physical order in both languages, matching the
        // web card: action on one side, identity and icon on the other.
        .environment(\.layoutDirection, .leftToRight)
    }

    // MARK: - Install

    /// The catalog entry this featured card stands for, if the catalog holds
    /// one. Several builds can share a bundle id, so the name is preferred
    /// when it disambiguates and the bundle id is the fallback.
    private func catalogApp(for app: FeaturedApp) -> RepoApp? {
        let all = repositories.repositories.flatMap { repositories.catalog[$0.id]?.apps ?? [] }
        let matches = all.filter { $0.bundleIdentifier == app.bundleId }
        return matches.first { $0.name == app.name } ?? matches.first
    }

    private func getButton(_ app: FeaturedApp) -> some View {
        let match = catalogApp(for: app)
        let isLoading = match.map { repositories.activeInstallID == $0.id } ?? false
        return GlassGetButton(
            isLoading: isLoading,
            isInstalled: false,
            disabled: match?.downloadURL == nil || !app.found ||
                (repositories.activeInstallID != nil && repositories.activeInstallID != match?.id)
        ) {
            guard let match else { return }
            if repositories.activeInstallID == match.id {
                repositories.cancelInstallAttempt(match.id)
            } else {
                repositories.clearInstalled(match.id)
                Task { await repositories.download(match) }
            }
        }
    }

    // MARK: - Detail sheet

    private func detailSheet(_ app: FeaturedApp) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    CachedAppIcon(url: app.iconURL, size: 66, cornerRadius: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(T.sans(20, .bold)).foregroundColor(T.ink)
                        Text(app.subtitle?.isEmpty == false ? app.subtitle! : app.bundleId)
                            .font(T.sans(13, .medium)).foregroundColor(T.ink3)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 0) {
                    stat(app.version.map { "v\($0)" } ?? "—", isArabic ? "النسخة" : "Version")
                    divider
                    stat(app.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—",
                         isArabic ? "الحجم" : "Size")
                    divider
                    stat(app.date.map { Self.dayFormatter.string(from: $0) } ?? "—",
                         isArabic ? "آخر تحديث" : "Updated")
                }
                .padding(.vertical, 14)
                .fGlass(cornerRadius: 16)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(T.rule, lineWidth: AppStroke.hairline)
                }

                if let note = app.note, !note.isEmpty {
                    Text(note).font(T.sans(13, .semibold)).foregroundColor(T.accent)
                }

                Text(isArabic ? "حول التطبيق" : "About")
                    .font(T.sans(13, .medium)).foregroundColor(T.ink3)
                Text(app.description?.isEmpty == false
                     ? app.description!
                     : (isArabic ? "لا يوجد وصف لهذا التطبيق." : "No description for this app."))
                    .font(T.sans(14, .regular))
                    .foregroundColor(T.ink2)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)

                if catalogApp(for: app) == nil || !app.found {
                    Text(isArabic ? "التطبيق غير متوفر حالياً." : "This app is currently unavailable.")
                        .font(T.sans(13, .medium))
                        .foregroundColor(T.warn)
                }

                getButton(app)
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
        }
        .background { ForgeBackdrop() }
    }

    private var divider: some View {
        Rectangle().fill(T.rule).frame(width: AppStroke.hairline, height: 30)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(T.sans(14, .semibold)).foregroundColor(T.ink).lineLimit(1)
            Text(label).font(T.sans(11, .medium)).foregroundColor(T.ink3)
        }
        .frame(maxWidth: .infinity)
    }

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    // MARK: - Networking

    private func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var request = URLRequest(url: Self.featuredURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            featured = try JSONDecoder().decode(FeaturedResponse.self, from: data).featured
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
