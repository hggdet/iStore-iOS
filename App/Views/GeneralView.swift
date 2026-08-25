import SwiftUI

/// General tab — Ceresify's paid products/services, mirroring the "عام"
/// page of Ceresify's own web app (its store section). No device/account
/// concept exists in iStore, so this is content-only: browse products,
/// order via Telegram.
struct GeneralView: View {
    @Environment(\.forgeTheme) private var T
    @Environment(\.openURL) private var openURL
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @State private var products: [CeresifyProduct] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var selectedProduct: CeresifyProduct?
    @State private var didLoad = false

    private static let productsURL = URL(string: "https://dev.ceresify.com/api/sign/products")!
    private static let telegramOrderUsername = "useceresify"

    private struct CeresifyProduct: Decodable, Identifiable {
        let name: String?
        let price: String?
        let rating: String?
        let imageUrl: String?
        let description: String?
        var id: String { name ?? "" }
    }

    private struct ProductsResponse: Decodable {
        let products: [CeresifyProduct]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        header
                        content
                    }
                    .padding(.top, 32)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
                .refreshable { await loadProducts() }
                .task {
                    guard !didLoad else { return }
                    didLoad = true
                    await loadProducts()
                }
            }
        }
        .sheet(item: $selectedProduct) { product in
            productDetailSheet(product)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(localized("General", "عام"))
                .font(T.display(28))
                .foregroundColor(T.ink)
            Text(localized("Ceresify products & services", "منتجات وخدمات سيريفاي"))
                .font(T.sans(13, .regular))
                .foregroundColor(T.ink2)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            stateCard(icon: nil, title: localized("Loading products…", "جارِ تحميل المنتجات…"), showsSpinner: true)
        } else if let errorMessage {
            stateCard(icon: "exclamationmark.triangle", title: localized("Couldn't load products", "تعذر تحميل المنتجات"), subtitle: errorMessage, retry: true)
        } else if products.isEmpty {
            stateCard(icon: "bag", title: localized("No products right now", "لا توجد منتجات حالياً"))
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(products.enumerated()), id: \.offset) { _, product in
                    productCard(product)
                }
            }
            .padding(.horizontal, T.pad)
        }
    }

    private func productCard(_ product: CeresifyProduct) -> some View {
        Button {
            selectedProduct = product
        } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    productImage(product.imageUrl)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()

                    if let rating = product.rating, !rating.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text(rating)
                                .font(T.sans(11, .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.55), in: Capsule())
                        .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(spacing: 4) {
                    Text(product.name ?? localized("Product", "منتج"))
                        .font(T.sans(12.5, .bold))
                        .foregroundColor(T.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(minHeight: 30)

                    if let price = product.price, !price.isEmpty {
                        Text(price)
                            .font(T.sans(13, .heavy))
                            .foregroundColor(T.accent)
                    }

                    orderButton(for: product)
                        .padding(.top, 3)
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 11)
                .padding(.top, 9)
            }
            .glassSurface(.card, cornerRadius: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(T.rule, lineWidth: AppStroke.hairline)
            }
        }
        .buttonStyle(GlassTactileButtonStyle())
    }

    /// Product photos are arbitrary marketing images, not square app icons —
    /// loaded directly instead of through `CachedAppIcon`'s 96px thumbnail cap.
    private func productImage(_ urlString: String?) -> some View {
        AsyncImage(url: urlString.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                Color.gray.opacity(0.18)
                    .overlay {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(T.ink3)
                    }
            }
        }
    }

    private func orderButton(for product: CeresifyProduct) -> some View {
        Button {
            openOrder(for: product.name)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 10))
                Text(localized("Order", "اطلب"))
                    .font(T.sans(11.5, .bold))
            }
            .foregroundColor(T.isDark ? .white : .black)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(T.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func productDetailSheet(_ product: CeresifyProduct) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Spacer().frame(height: 40)

                    productImage(product.imageUrl)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(T.rule, lineWidth: AppStroke.hairline)
                        }

                    Text(product.name ?? localized("Product", "منتج"))
                        .font(T.sans(20, .bold))
                        .foregroundColor(T.ink)
                        .multilineTextAlignment(.center)

                    if let price = product.price, !price.isEmpty {
                        Text(price)
                            .font(T.sans(16, .heavy))
                            .foregroundColor(T.accent)
                    }

                    if let description = product.description, !description.isEmpty {
                        Text(description)
                            .font(T.sans(14, .regular))
                            .foregroundColor(T.ink2)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(localized("No description available.", "لا يوجد وصف."))
                            .font(T.sans(14, .regular))
                            .foregroundColor(T.ink3)
                    }

                    Button {
                        openOrder(for: product.name)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "paperplane.fill")
                            Text(localized("Order Now", "اطلب الآن"))
                        }
                        .font(T.sans(16, .bold))
                        .foregroundColor(T.isDark ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(T.isDark ? Color.white : Color.black, in: Capsule())
                    }
                    .buttonStyle(GlassTactileButtonStyle())
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background { ForgeBackdrop() }
            .toolbar(.hidden, for: .navigationBar)
        }
        .floatingGlassBackButton(action: { selectedProduct = nil })
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(34)
        .presentationDragIndicator(.hidden)
        .presentationBackground { ForgeBackdrop() }
    }

    private func stateCard(icon: String?, title: String, subtitle: String? = nil, showsSpinner: Bool = false, retry: Bool = false) -> some View {
        VStack(spacing: T.gap) {
            if showsSpinner {
                ProgressView().tint(T.ink3)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(T.ink3)
            }
            Text(title)
                .font(T.sans(15, .medium))
                .foregroundColor(T.ink)
            if let subtitle {
                MonoText(text: subtitle, size: 10, color: T.ink3)
            }
            if retry {
                Button {
                    Task { await loadProducts() }
                } label: {
                    Text(localized("Retry", "إعادة المحاولة"))
                        .font(T.sans(13, .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(T.accent)
                .padding(.top, 4)
            }
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
    }

    private func openOrder(for productName: String?) {
        let name = productName ?? localized("this product", "هذا المنتج")
        let text = localized("Hi, I'd like to order: ", "مرحبا اريد شراء ") + name
        var comps = URLComponents(string: "https://t.me/\(Self.telegramOrderUsername)")
        comps?.queryItems = [URLQueryItem(name: "text", value: text)]
        guard let url = comps?.url else { return }
        openURL(url)
    }

    private func loadProducts() async {
        isLoading = products.isEmpty
        errorMessage = nil
        do {
            var req = URLRequest(url: Self.productsURL)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                errorMessage = localized("The server returned an error.", "الخادم أرجع خطأ.")
                isLoading = false
                return
            }
            let decoded = try JSONDecoder().decode(ProductsResponse.self, from: data)
            products = decoded.products
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func localized(_ english: String, _ arabic: String) -> String {
        languageCode == AppLanguage.arabic.rawValue ? arabic : english
    }
}
