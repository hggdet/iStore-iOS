import SwiftUI
import UniformTypeIdentifiers

/// Picker + manager for remembered signing certificates. Shows remaining
/// validity per certificate, imports new .p12 files (validated against a
/// password) and optionally stores the password in the Keychain.
struct CertificatesSheet: View {
    private enum ImportMode {
        case p12
        case provisioningProfile
    }

    @EnvironmentObject private var store: CertificateStore
    @EnvironmentObject private var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.forgeTheme) private var T
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @State private var showImporter = false
    @State private var importMode: ImportMode?
    @State private var pendingURL: URL?
    @State private var pendingPassword = ""
    @State private var rememberPassword = true
    @State private var error: String?
    @State private var profileError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        if let pendingURL {
                            verifyCard(pendingURL)
                        }

                        if store.certificates.isEmpty && pendingURL == nil {
                            emptyState
                        } else if !store.certificates.isEmpty {
                            GlassSection(localized("Saved", "المحفوظة")) {
                                VStack(spacing: 0) {
                                    ForEach(Array(store.certificates.enumerated()), id: \.element.id) { index, cert in
                                        row(cert)
                                        if index < store.certificates.count - 1 {
                                            GlassRowDivider()
                                        }
                                    }
                                }
                            }
                        }

                        GlassSecondaryButton(label: localized("Certificate", "الشهادة"), systemImage: "key.fill") {
                            importMode = .p12
                            DispatchQueue.main.async {
                                showImporter = true
                            }
                        }
                        .padding(.horizontal, T.pad)
                        .padding(.top, 24)

                        GlassSecondaryButton(label: localized("Provisioning Profile", "ملف Provisioning"), systemImage: "checkmark.seal.fill") {
                            importMode = .provisioningProfile
                            DispatchQueue.main.async {
                                showImporter = true
                            }
                        }
                        .padding(.horizontal, T.pad)
                        .padding(.top, 12)

                        if let profileError {
                            Text(profileError)
                                .font(T.mono(10))
                                .foregroundColor(T.bad)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, T.pad)
                                .padding(.top, 10)
                        }
                    }
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .navigationTitle(localized("Certificates", "الشهادة"))
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showImporter) {
                    ForgeDocumentPicker { urls in
                        showImporter = false
                        let mode = importMode
                        importMode = nil

                        guard let url = urls.first else { return }

                        switch mode {
                        case .p12:
                            let ext = url.pathExtension.lowercased()
                            guard ext == "p12" || ext == "pfx" else {
                                error = localized("Please choose a .p12 or .pfx certificate.", "يرجى اختيار شهادة بامتداد .p12 أو .pfx.")
                                return
                            }
                            pendingURL = url
                            pendingPassword = ""
                            error = nil
                        case .provisioningProfile:
                            guard url.pathExtension.lowercased() == "mobileprovision" else {
                                profileError = localized("Please choose a .mobileprovision profile.", "يرجى اختيار ملف حماية بامتداد .mobileprovision.")
                                return
                            }
                            switch profileStore.importProfile(from: url) {
                            case .success:
                                profileError = nil
                            case .failure(let failure):
                                profileError = localizedProfileError(failure)
                            }
                        case .none:
                            break
                        }
                    } onCancel: {
                        showImporter = false
                        importMode = nil
                    }
                    .ignoresSafeArea()
                }
            }
        }
        .floatingGlassBackButton(action: { dismiss() })
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func localized(_ english: String, _ arabic: String) -> String {
        languageCode == AppLanguage.arabic.rawValue ? arabic : english
    }

    private var emptyState: some View {
        VStack(spacing: T.gap) {
            Image(systemName: "key.fill")
                .font(.system(size: 20))
                .foregroundColor(T.ink3)
            Text(localized("No saved certificates", "لا توجد شهادات محفوظة"))
                .font(T.sans(15))
                .foregroundColor(T.ink)
            MonoText(text: localized("Import a .p12 once — it stays on this device.", "استورد ملف .p12 مرة واحدة — وسيبقى محفوظاً على هذا الجهاز."), size: 10, color: T.ink3)
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

    private func row(_ cert: CertificateRecord) -> some View {
        let expiry = P12Inspector.expiry(cert.notAfter, languageCode: languageCode)

        return HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(T.accent2)
                .frame(width: 38, height: 38)
                .fClearGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(languageCode == AppLanguage.arabic.rawValue ? "الشهادة" : "Certificate")
                    .font(T.sans(16, .bold))
                    .foregroundColor(T.ink)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    certificateAction(
                        title: expiry.text,
                        systemImage: "calendar",
                        tint: expiry.tone.color(in: T)
                    )

                    certificateAction(
                        title: localized("Delete Certificate", "حذف الشهادة"),
                        systemImage: "trash",
                        tint: T.bad
                    ) {
                        store.delete(cert)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedID = cert.id
        }
        .contextMenu {
            Button(localized("Delete", "حذف"), role: .destructive) { store.delete(cert) }
        }
    }

    private func certificateAction(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(T.mono(9, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .foregroundColor(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .padding(.horizontal, 7)
            .fClearGlass(in: Capsule(), interactive: true)
        }
        .buttonStyle(GlassTactileButtonStyle())
    }


    private func verifyCard(_ url: URL) -> some View {
        VStack(spacing: T.gap) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(T.accent2)
                Text(url.lastPathComponent)
                    .font(T.mono(11))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

            SecureField(localized("P12 password", "كلمة مرور P12"), text: $pendingPassword)
                .textFieldStyle(.plain)
                .font(T.mono(13))
                .foregroundColor(T.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(T.surface3)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(T.rule, lineWidth: AppStroke.hairline)
                }

            HStack(spacing: 12) {
                Text(localized("Remember password in Keychain", "حفظ كلمة المرور في سلسلة المفاتيح"))
                    .font(T.sans(13, .medium))
                    .foregroundColor(T.ink)
                Spacer(minLength: 8)
                GlassToggle(isOn: $rememberPassword)
            }

            if let error {
                Text(error)
                    .font(T.mono(10))
                    .foregroundColor(T.bad)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                GlassSecondaryButton(label: localized("Cancel", "إلغاء")) {
                    pendingURL = nil
                    pendingPassword = ""
                    error = nil
                }
                GlassPrimaryButton(label: localized("Verify & Save", "تحقق وحفظ"), systemImage: "checkmark.seal") {
                    verify(url)
                }
            }
        }
        .padding(16)
        .fGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private func verify(_ url: URL) {
        switch store.importCertificate(from: url, password: pendingPassword,
                                       rememberPassword: rememberPassword) {
        case .success:
            pendingURL = nil
            pendingPassword = ""
            error = nil
        case .failure(let failure):
            error = localizedCertificateError(failure)
        }
    }

    private func localizedCertificateError(_ failure: CertificateStore.ImportError) -> String {
        switch failure {
        case .unreadable:
            return localized("The file could not be read.", "تعذر قراءة الملف.")
        case .badPassword:
            return localized("Wrong password, or not a valid signing certificate.", "كلمة المرور خاطئة أو أن الملف ليس شهادة توقيع صالحة.")
        case .copyFailed:
            return localized("The certificate could not be saved.", "تعذر حفظ الشهادة داخل التطبيق.")
        }
    }

    private func localizedProfileError(_ failure: ProfileStore.ImportError) -> String {
        switch failure {
        case .unreadable:
            return localized("The file could not be read.", "تعذر قراءة الملف.")
        case .notAProfile:
            return localized("Not a valid .mobileprovision file.", "الملف ليس Provisioning Profile صالحاً.")
        case .copyFailed:
            return localized("The profile could not be saved.", "تعذر حفظ ملف الحماية داخل التطبيق.")
        }
    }
}
