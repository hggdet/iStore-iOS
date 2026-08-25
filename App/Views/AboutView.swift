import SwiftUI
import UIKit

/// About tab — restyled to match Ceresify's own Settings page: a page
/// header, then grouped "eyebrow + list-card" sections (`GlassSection`)
/// instead of the previous free-form cards.
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
                    VStack(spacing: 0) {
                        header
                        GlassSection(localized("Preferences", "التفضيلات")) {
                            languageRow(.arabic, label: "العربية")
                            GlassRowDivider()
                            languageRow(.english, label: "English")
                        }
                        GlassSection(localized("Connect with us", "تواصل معنا")) {
                            linkRow(title: localized("Telegram", "تيليجرام"), icon: "paperplane.fill", brandAsset: nil, url: telegramURL)
                            GlassRowDivider()
                            linkRow(title: "TikTok", icon: nil, brandAsset: "TikTokLogo", url: tiktokURL)
                        }
                        developerCredit
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

    private var header: some View {
        VStack(spacing: 8) {
            Image("iStoreIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
                .padding(.bottom, 6)

            Text("iStore")
                .font(T.display(28))
                .foregroundColor(T.ink)

            Text(localized(
                "A specialized tool for signing and installing IPA apps directly on your device",
                "أداة متخصصة لتوقيع وتثبيت تطبيقات IPA مباشرة على جهازك"
            ))
                .font(T.sans(13, .regular))
                .foregroundColor(T.ink2)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.horizontal, 36)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
    }

    private func languageRow(_ lang: AppLanguage, label: String) -> some View {
        let isActive = languageCode == lang.rawValue
        return Button {
            let haptic = UIImpactFeedbackGenerator(style: .light)
            haptic.prepare()
            haptic.impactOccurred()
            languageCode = lang.rawValue
            UserDefaults.standard.set(true, forKey: "app.language.userSelected")
        } label: {
            HStack(spacing: 13) {
                rowIcon("globe")
                Text(label)
                    .font(T.sans(15, .medium))
                    .foregroundColor(T.ink)
                Spacer(minLength: 8)
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(T.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassTactileButtonStyle())
    }

    private func linkRow(title: String, icon: String?, brandAsset: String?, url: String) -> some View {
        Button {
            let haptic = UIImpactFeedbackGenerator(style: .light)
            haptic.prepare()
            haptic.impactOccurred()
            guard let destination = URL(string: url) else { return }
            openURL(destination)
        } label: {
            HStack(spacing: 13) {
                if let brandAsset {
                    rowIconImage(brandAsset)
                } else if let icon {
                    rowIcon(icon)
                }
                Text(LocalizedStringKey(title))
                    .font(T.sans(15, .medium))
                    .foregroundColor(T.ink)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(T.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassTactileButtonStyle())
    }

    private func rowIcon(_ systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(T.accentSoft)
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(T.accent2)
        }
        .frame(width: 32, height: 32)
    }

    private func rowIconImage(_ assetName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(T.accentSoft)
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 15, height: 15)
        }
        .frame(width: 32, height: 32)
    }

    private var developerCredit: some View {
        Button {
            guard let destination = URL(string: telegramURL) else { return }
            openURL(destination)
        } label: {
            VStack(spacing: 3) {
                Text(LocalizedStringKey(developerName))
                    .font(T.sans(15, .semibold))
                    .foregroundColor(T.accent)
                Text(localized("Programming & design", "برمجة وتصميم"))
                    .font(T.sans(11, .regular))
                    .foregroundColor(T.ink3)
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 20)
    }

    private func localized(_ english: String, _ arabic: String) -> String {
        languageCode == AppLanguage.arabic.rawValue ? arabic : english
    }
}
