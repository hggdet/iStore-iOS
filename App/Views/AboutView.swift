import SwiftUI
import UIKit

struct AboutView: View {
    @Environment(\.forgeTheme) private var T
    @Environment(\.openURL) private var openURL
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    private let developerName = "عبدالباسط خضير"
    private let telegramURL = "https://t.me/ipafilesfor"
    private let tiktokURL = "https://www.tiktok.com/@087.n"

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 16) {
                        aboutInfoCard
                        contactSettingsCard
                    }
                    .padding(.top, 32)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
            }
        }
    }

    private var aboutInfoCard: some View {
        VStack(spacing: 0) {
            Image("iStoreIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
                .padding(.bottom, 14)

            Text("iStore")
                .font(T.display(28))
                .foregroundColor(T.ink)
                .multilineTextAlignment(.center)

            VStack(spacing: 5) {
                Text("Developer")
                    .font(T.sans(15, .medium))
                    .foregroundColor(T.ink2)

                Text(LocalizedStringKey(developerName))
                    .font(T.sans(19, .semibold))
                    .foregroundColor(T.ink)
            }
            .padding(.top, 18)

            shortDivider
                .padding(.top, 20)

            Text("A specialized tool for signing and installing IPA apps directly on your device")
                .font(T.sans(14, .regular))
                .foregroundColor(T.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 22)
                .padding(.top, 18)
        }
        .cardSurface
    }

    private var contactSettingsCard: some View {
        VStack(spacing: 0) {
            Text("Contact Developer")
                .font(T.sans(16, .semibold))
                .foregroundColor(T.ink)

            HStack(spacing: 12) {
                socialButton(title: "Telegram", icon: "paperplane.fill", brandAsset: nil, url: telegramURL)
                socialButton(title: "TikTok", icon: nil, brandAsset: "TikTokLogo", url: tiktokURL)
            }
            .padding(.top, 14)

            Menu {
                Button("English") {
                    languageCode = AppLanguage.english.rawValue
                    UserDefaults.standard.set(true, forKey: "app.language.userSelected")
                }
                Button("Arabic") {
                    languageCode = AppLanguage.arabic.rawValue
                    UserDefaults.standard.set(true, forKey: "app.language.userSelected")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Language")
                        .font(T.sans(13.5, .semibold))
                    Spacer()
                    Text(languageCode == AppLanguage.arabic.rawValue
                         ? LocalizedStringKey("Arabic")
                         : LocalizedStringKey("English"))
                        .font(T.sans(12.5, .medium))
                }
                .foregroundColor(T.ink)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .glassSurface(.button, cornerRadius: 15)
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(T.rule, lineWidth: AppStroke.hairline)
                }
            }
            .buttonStyle(GlassTactileButtonStyle())
            .padding(.top, 12)
        }
        .cardSurface
    }

    private var shortDivider: some View {
        Rectangle()
            .fill(T.rule)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
    }

    private func socialButton(title: String, icon: String?, brandAsset: String?, url: String) -> some View {
        Button {
            let haptic = UIImpactFeedbackGenerator(style: .light)
            haptic.prepare()
            haptic.impactOccurred()
            guard let destination = URL(string: url) else { return }
            openURL(destination)
        } label: {
            HStack(spacing: 8) {
                if let brandAsset {
                    Image(brandAsset)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundColor(T.isDark ? .white : .black)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(LocalizedStringKey(title))
                    .font(T.sans(13.5, .semibold))
            }
            .foregroundColor(T.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .fClearGlass(
                in: RoundedRectangle(cornerRadius: 15, style: .continuous),
                interactive: true,
                showRim: false,
                useRegularInteractiveGlass: true
            )
        }
        .buttonStyle(GlassTactileButtonStyle())
    }
}

private extension View {
    var cardSurface: some View {
        self
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .glassSurface(.card, cornerRadius: 22)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: AppStroke.hairline)
            }
            .padding(.horizontal, 16)
    }
}
