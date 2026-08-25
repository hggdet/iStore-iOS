import SwiftUI
import Foundation
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var signer = SigningService()

    @EnvironmentObject private var certStore: CertificateStore
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var history: HistoryStore
    @EnvironmentObject private var install: InstallController
    @EnvironmentObject private var repoStore: RepositoryStore
    @Environment(\.forgeTheme) private var T
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @State private var ipaURL: URL?
    @State private var importedAppURLs: [URL] = []
    @State private var password = ""
    @State private var bundleId = ""
    @State private var removeExtensions = false
    @State private var enableDocuments = false
    @State private var dylibURL: URL?
    @State private var injectIntoExtensions = false
    @State private var preflightState: IPAPreflightState = .idle
    @State private var signedIPA: URL?
    @State private var signedBundleId = ""
    @State private var signedVersion = "1.1"
    @State private var lastRecordID: UUID?
    @State private var automaticInstallAppID: String?
    @State private var automaticInstallAsAdditionalCopy = false
    @State private var showIPAImporter = false
    @State private var showImportSheet = false
    @State private var showProfileSheet = false
    @State private var showCertSheet = false
    @State private var showAppEditor = false
    @State private var importURLText = ""
    @State private var isDownloadingImport = false
    @State private var appDisplayName = ""
    @State private var appVersion = ""
    @State private var selectedIconURL: URL?
    @State private var showShare = false
    @State private var showLibrary = false

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 0) {
                        importSection
                        certificateSection
                        workspaceSection
                    }
                    .padding(.top, 30)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)
                .background { ForgeBackdrop() }
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $showIPAImporter) {
                    ForgeDocumentPicker { urls in
                        showIPAImporter = false
                        guard let url = urls.first else { return }
                        let ext = url.pathExtension.lowercased()
                        guard ext == "ipa" || ext == "zip" else { return }
                        stageIPA(url)
                    } onCancel: {
                        showIPAImporter = false
                    }
                    .ignoresSafeArea()
                }
                .sheet(isPresented: $showImportSheet) {
                    ImportApplicationSheet(
                        importURLText: $importURLText,
                        isDownloadingURL: isDownloadingImport,
                        onImportURL: importFromURL,
                        ipaURL: ipaURL,
                        appName: appDisplayName,
                        bundleID: bundleId,
                        preflightState: preflightState,
                        importedURLs: importedAppURLs,
                        onIPA: { selectedURL in
                            stageIPA(selectedURL)
                            showImportSheet = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                showAppEditor = true
                            }
                        },
                        onOpenApp: { selectedURL in
                            if selectedURL != ipaURL {
                                stageIPA(selectedURL)
                            }
                            presentAfterImportDismiss { showAppEditor = true }
                        }
                    )
                    .liquidGlassSheet()
                }
                .sheet(isPresented: $showProfileSheet) {
                    ProfilesSheet()
                }
                .sheet(isPresented: $showCertSheet) {
                    CertificatesSheet()
                        .liquidGlassSheet()
                }
                .sheet(isPresented: $showShare) {
                    if let signedIPA { ShareSheet(items: [signedIPA]) }
                }
                .sheet(isPresented: $showAppEditor) {
                    AppEditorSheet(appName: $appDisplayName,
                                   bundleID: $bundleId,
                                   version: $appVersion,
                                   password: $password,
                                   hasSavedPassword: certStore.selected.flatMap { certStore.savedPassword(for: $0) } != nil,
                                   certificateName: certStore.selected?.shortDisplayName,
                                   profileName: profileStore.selected?.displayName,
                                   preflightState: preflightState,
                                   isSigning: signer.phase == .signing,
                                   canSign: canSign,
                                   dylibURL: dylibURL,
                                   iconURL: selectedIconURL,
                                   shareURL: signedIPA ?? ipaURL,
                                   removeExtensions: $removeExtensions,
                                   enableDocuments: $enableDocuments,
                                   onChooseIcon: { url in
                                       selectedIconURL = signer.stage(url, as: "custom-icon-\(url.lastPathComponent)")
                                   },
                                   onChoosePhoto: { item in
                                       guard let item else { return }
                                       Task { @MainActor in
                                           if let data = try? await item.loadTransferable(type: Data.self) {
                                               let iconURL = signer.workDir.appendingPathComponent("custom-icon.png")
                                               try? data.write(to: iconURL, options: .atomic)
                                               selectedIconURL = iconURL
                                           }
                                       }
                                   },
                                   onChooseCertificate: { showCertSheet = true },
                                   onChooseProfile: { showProfileSheet = true },
                                   onChooseDylib: { url in stageDylib(url) },
                                   onRemoveDylib: {
                                       dylibURL = nil
                                       injectIntoExtensions = false
                                   },
                                   onSignOnly: { sign(installAfter: false) },
                                   onSign: { sign(installAfter: true) })
                }
                .sheet(isPresented: $showLibrary) {
                    LibraryView { record in
                        install.install(ipa: history.outputURL(for: record),
                                        bundleId: record.bundleId,
                                        version: record.version)
                    }
                    .liquidGlassSheet()
                }
                .onChange(of: install.installStatus) { status in
                    if status.hasPrefix("Install failed") {
                        if let id = lastRecordID {
                            history.setInstallState(.failed, for: id)
                        }
                        repoStore.completeInstallAttempt(automaticInstallAppID, error: status)
                        automaticInstallAppID = nil
                        automaticInstallAsAdditionalCopy = false
                    }
                }
                .task {
                    if let pendingIPA = repoStore.pendingIPA {
                        await receiveDownloadedRepositoryIPA(pendingIPA)
                    }
                }
                .onChange(of: repoStore.pendingIPA) { pendingIPA in
                    guard let pendingIPA else { return }
                    Task {
                        await receiveDownloadedRepositoryIPA(pendingIPA)
                    }
                }
            }
        }
    }

    /// Claims one completed repository download, stages it for signing, and
    /// starts the automatic signing path. Clearing `pendingIPA` happens first
    /// so a tab change cannot trigger duplicate work for the same file.
    @MainActor
    private func receiveDownloadedRepositoryIPA(_ pendingIPA: URL) async {
        guard repoStore.pendingIPA == pendingIPA else { return }

        let downloadedAppID = repoStore.pendingAppID
        let downloadedAppName = repoStore.pendingAppName
        let installAsAdditionalCopy = repoStore.pendingInstallAsAdditionalCopy
        repoStore.pendingIPA = nil
        repoStore.pendingAppID = nil
        repoStore.pendingAppName = nil
        repoStore.pendingInstallAsAdditionalCopy = false

        automaticInstallAppID = downloadedAppID
        automaticInstallAsAdditionalCopy = installAsAdditionalCopy
        // The repository download is already inside iStore's persistent
        // download directory. Reuse it directly instead of copying a large
        // IPA synchronously on MainActor before signing.
        stageIPA(pendingIPA, fallbackToSource: true, alreadyStaged: true)

        guard ipaURL != nil else {
            let message = localized(
                "The downloaded IPA could not be prepared for signing.",
                "تعذر تجهيز ملف IPA الذي تم تنزيله للتوقيع."
            )
            repoStore.completeInstallAttempt(downloadedAppID, error: message)
            automaticInstallAppID = nil
            automaticInstallAsAdditionalCopy = false
            return
        }

        if let downloadedAppName, !downloadedAppName.isEmpty {
            appDisplayName = downloadedAppName
        }

        if installAsAdditionalCopy, let downloadedAppName, !downloadedAppName.isEmpty {
            // Keep a stable per-app counter so every generated copy has a
            // distinct visible name: App 2, App 3, App 4, and so on.
            let copyNumber = nextRepeatDisplayNumber(for: downloadedAppID)
            appDisplayName = "\(downloadedAppName) \(copyNumber)"
        }

        // GET is a silent install flow: close only any editor left from a
        // previous manual import. Keep the storefront visible while signing
        // and handing the IPA to iOS.
        showAppEditor = false
        await autoSignDownloadedIPAWhenReady()
    }

    private func nextRepeatDisplayNumber(for appID: String?) -> Int {
        guard let appID, !appID.isEmpty else { return 2 }
        let key = "repo.repeat.displayNumber.\(appID)"
        let next = max(UserDefaults.standard.integer(forKey: key) + 1, 2)
        UserDefaults.standard.set(next, forKey: key)
        return next
    }

    private func additionalCopyIdentifier(from original: String) -> String? {
        let base = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6).lowercased()
        let prefix = String(base.prefix(230)).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let candidate = "\(prefix).copy\(token)"
        return candidate.count <= 255 ? candidate : nil
    }

    // MARK: - Import

    private var importSection: some View {
        Button {
            showImportSheet = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(T.isDark ? .white : T.ink)
                    .frame(width: 40, height: 40)
                    .fClearGlass(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(localized("Import Application", "استيراد تطبيق"))
                    .font(T.sans(17, .bold))
                    .foregroundColor(T.isDark ? .white : T.ink)
                Spacer()
            }
            .foregroundColor(T.ink)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 66)
            .contentShape(Rectangle())
            .glassSurface(.button, cornerRadius: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(T.rule, lineWidth: AppStroke.hairline)
            }
        }
        .buttonStyle(GlassTactileButtonStyle())
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity)
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    private var certificateSection: some View {
        Button {
            showCertSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(T.isDark ? .white : T.ink)
                    .frame(width: 40, height: 40)
                    .fClearGlass(in: RoundedRectangle(cornerRadius: 11, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(certStore.selected == nil
                         ? localized("Import Certificate", "استيراد شهادة")
                         : localized("Apple Distribution", "شهادة التوزيع"))
                        .font(T.sans(17, .bold))
                        .foregroundColor(T.isDark ? .white : T.ink)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 66)
            .contentShape(Rectangle())
            .foregroundColor(T.ink)
            .glassSurface(.button, cornerRadius: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(T.rule, lineWidth: AppStroke.hairline)
            }
        }
        .buttonStyle(GlassTactileButtonStyle())
        .frame(maxWidth: .infinity)
        .padding(.horizontal, T.pad)
        .padding(.top, 14)
    }

    private var yourApplicationsSection: some View {
        GlassSection("Your Application") {
            if importedAppURLs.isEmpty {
                emptyMainState(icon: "square.and.arrow.down", text: "Import an application to get started")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(importedAppURLs.enumerated()), id: \.element.path) { index, url in
                        Button {
                            if url.path != ipaURL?.path { stageIPA(url) }
                            showAppEditor = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(T.accent2)
                                    .frame(width: 40, height: 40)
                                    .fClearGlass(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(url.path == ipaURL?.path && !appDisplayName.isEmpty ? appDisplayName : url.deletingPathExtension().lastPathComponent)
                                        .font(T.sans(15, .medium))
                                        .foregroundColor(T.ink)
                                        .lineLimit(1)
                                    Text(url.path == ipaURL?.path ? "Ready to edit and sign" : "Imported application")
                                        .font(T.mono(9))
                                        .foregroundColor(T.ink3)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(GlassTactileButtonStyle())
                        if index < importedAppURLs.count - 1 { GlassRowDivider() }
                    }
                }
            }
        }
    }

    private var libraryPreviewSection: some View {
        GlassSection("Library") {
            if history.records.isEmpty {
                emptyMainState(icon: "shippingbox", text: "Signed applications will appear here")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.records.prefix(3).enumerated()), id: \.element.id) { index, record in
                        Button { showLibrary = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(T.accent2)
                                    .frame(width: 40, height: 40)
                                    .fClearGlass(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.outputName)
                                        .font(T.mono(12, .medium))
                                        .foregroundColor(T.ink)
                                        .lineLimit(1)
                                    Text(record.bundleId)
                                        .font(T.mono(9))
                                        .foregroundColor(T.ink3)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(record.installState.rawValue)
                                    .font(T.mono(9, .semibold))
                                    .foregroundColor(T.accent)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(GlassTactileButtonStyle())
                        if index < min(history.records.count, 3) - 1 { GlassRowDivider() }
                    }
                }
            }
        }
    }

    private func localized(_ english: String, _ arabic: String) -> String {
        languageCode == AppLanguage.arabic.rawValue ? arabic : english
    }

    private func presentAfterImportDismiss(_ action: @escaping () -> Void) {
        showImportSheet = false
        // Wait for the sheet dismissal transaction to finish before presenting
        // a file importer or another sheet. Presenting both in the same frame
        // makes iOS ignore the second presentation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            action()
        }
    }

    private func emptyMainState(icon: String, text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundColor(T.ink3)
            Text(LocalizedStringKey(text))
                .font(T.sans(13, .medium))
                .foregroundColor(T.ink3)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
    }

    private func importButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(LocalizedStringKey(title))
                    .font(T.sans(15, .semibold))
            }
            .foregroundColor(T.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
                        .glassSurface(.button, cornerRadius: 16)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous)

                    .stroke(T.rule, lineWidth: AppStroke.hairline)
            }
        }
        .buttonStyle(GlassTactileButtonStyle())
    }

    private func importedAppCard(url: URL) -> some View {
        Button {
            showAppEditor = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "app.fill")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundColor(T.accent2)
                    .frame(width: 58, height: 58)
                    .glassSurface(.button, cornerRadius: 15)

                VStack(alignment: .leading, spacing: 5) {
                    Text(appDisplayName.isEmpty ? url.deletingPathExtension().lastPathComponent : appDisplayName)
                        .font(T.sans(16, .semibold))
                        .foregroundColor(T.ink)
                        .lineLimit(1)
                    if case .ready(let inspection) = preflightState {
                        Text(inspection.bundleIdentifier)
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                            .lineLimit(1)
                    } else if case .inspecting = preflightState {
                        Text("Reading app details…")
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                    } else {
                        Text("Tap to edit and sign")
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(.card, cornerRadius: 18)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(T.rule, lineWidth: AppStroke.hairline)
            }
        }
        .buttonStyle(GlassTactileButtonStyle())
        .padding(.horizontal, T.pad)
        .padding(.top, 18)
    }

    // MARK: - Workspace

    private var workspaceSection: some View {
        VStack(spacing: 14) {
            automaticInstallStatus

            GlassSecondaryButton(label: localized("Library", "المكتبة"), systemImage: "clock.arrow.circlepath") {
                showLibrary = true
            }
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 14)
    }

    @ViewBuilder
    private var automaticInstallStatus: some View {
        switch signer.phase {
        case .signing:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(T.accent)
                Text(localized("Signing and preparing the iOS install…", "جارِ توقيع التطبيق وتجهيز التثبيت على iOS…"))
                    .font(T.sans(13, .semibold))
                    .foregroundColor(T.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .glassSurface(.card, cornerRadius: 16)

        case .failed(let message):
            errorCard(message)
                .padding(.horizontal, 2)

        case .done(let message):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(T.good)
                Text(message)
                    .font(T.sans(13, .semibold))
                    .foregroundColor(T.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .glassSurface(.card, cornerRadius: 16)

        case .idle:
            EmptyView()
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        GlassSection("Input") {
            GlassFileRow(icon: "doc.zipper", label: "IPA", file: ipaURL) { showIPAImporter = true }
            GlassRowDivider()
            certificateRow
            GlassRowDivider()
            profileRow
            GlassRowDivider()
            if let cert = certStore.selected, certStore.savedPassword(for: cert) != nil {
                GlassRow(label: "P12 password") {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(T.accent2)
                        GlassStatusPill(text: "Keychain", color: T.accent)
                    }
                }
            } else {
                GlassInputRow(icon: "lock.fill", label: "P12 password", placeholder: "Required", text: $password, isSecure: true)
            }
        }
    }

    private var certificateRow: some View {
        Button {
            showCertSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(T.accent2)
                    .frame(width: 40, height: 40)
                    .fClearGlass(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(localized("Certificate (.p12)", "الشهادة (.p12)"))
                    .font(T.sans(15, .medium))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let cert = certStore.selected {
                    let expiry = P12Inspector.expiry(cert.notAfter)
                    GlassStatusPill(text: expiry.text, color: expiry.tone.color(in: T))
                    Text(cert.shortDisplayName)
                        .font(T.mono(12))
                        .foregroundColor(T.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 130, alignment: .trailing)
                } else {
                    Text(localized("Choose…", "اختيار…"))
                        .font(T.sans(13, .medium))
                        .foregroundColor(T.ink3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassTactileButtonStyle())
    }

    private var profileRow: some View {
        Button {
            showProfileSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(T.accent2)
                    .frame(width: 40, height: 40)
                    .fClearGlass(in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(localized("Profile (.mobileprovision)", "ملف الحماية (.mobileprovision)"))
                    .font(T.sans(15, .medium))
                    .foregroundColor(T.ink)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let profile = profileStore.selected {
                    let expiry = P12Inspector.expiry(profile.notAfter)
                    GlassStatusPill(text: expiry.text, color: expiry.tone.color(in: T))
                    Text(profile.displayName)
                        .font(T.mono(12))
                        .foregroundColor(T.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 130, alignment: .trailing)
                } else {
                    Text(localized("Choose…", "اختيار…"))
                        .font(T.sans(13, .medium))
                        .foregroundColor(T.ink3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(GlassTactileButtonStyle())
    }

    // MARK: - Options

    private var optionsSection: some View {
        GlassSection("Options") {
            GlassInputRow(icon: "curlybraces", label: "New bundle ID", placeholder: "Optional", text: $bundleId)
            GlassRowDivider()
            GlassToggleRow(label: "Remove app extensions", isOn: $removeExtensions)
            GlassRowDivider()
            GlassToggleRow(label: "Enable Files import / sharing", isOn: $enableDocuments)
        }
    }

    // MARK: - Sign CTA

    private var signButton: some View {
        let signing = signer.phase == .signing
        return Button(action: { sign() }) {
            HStack(spacing: 8) {
                if signing {
                    ProgressView()
                        .tint(.white)
                    Text("Signing…").font(T.sans(15, .semibold))
                } else {
                    Image(systemName: "signature")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Sign IPA").font(T.sans(15, .semibold))
                }
            }
            .foregroundColor(T.isDark ? .white : T.ink)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .frame(maxWidth: .infinity)
            .glassSurface(.button)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(T.rule2, lineWidth: AppStroke.hairline)
            }
            .shimmer(isActive: signing)
            .opacity(!canSign || signing ? 0.45 : 1)
        }
        .buttonStyle(GlassTactileButtonStyle())
        .disabled(!canSign || signing)
        .padding(.horizontal, T.pad)
        .padding(.top, 28)
    }

    // MARK: - Error

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(T.bad)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(T.bad)
                .padding(.top, 1)
            Text(message)
                .font(T.mono(11))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .fGlass(cornerRadius: 14)
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(T.bad.opacity(0.35), lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .padding(.top, 24)
    }

    // MARK: - Result

    private func resultSection(_ signedIPA: URL) -> some View {
        GlassSection("Result") {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    GlassStatusPill(text: "Signed", color: T.good)
                    Text(signedIPA.lastPathComponent)
                        .font(T.mono(12))
                        .foregroundColor(T.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                GlassRowDivider()

                GlassRow(label: "Bundle ID") {
                    Text(signedBundleId)
                        .font(T.mono(12))
                        .foregroundColor(T.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !install.installStatus.isEmpty {
                    GlassRowDivider()
                    HStack(spacing: 8) {
                        Image(systemName: "iphone")
                            .font(.system(size: 11))
                            .foregroundColor(T.accent2)
                        Text(install.installStatus)
                            .font(T.mono(10))
                            .foregroundColor(T.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }

                GlassRowDivider()

                VStack(spacing: T.gap) {
                    GlassPrimaryButton(label: "Install on Device", systemImage: "arrow.down.app") {
                        startInstall()
                    }
                    if install.installServer != nil {
                        GlassSecondaryButton(label: "Retry via Safari", systemImage: "safari") {
                            install.openInstallPage()
                        }
                    }
                    GlassSecondaryButton(label: "Share / Save signed IPA", systemImage: "square.and.arrow.up") {
                        showShare = true
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Import URL

    private func importFromURL() {
        let raw = importURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }

        isDownloadingImport = true
        Task { @MainActor in
            defer {
                isDownloadingImport = false
            }
            do {
                let (downloadedURL, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { return }
                // URLSession's temporary file is ours; move it instead of
                // copying so a 400 MB import costs no extra pass over the data.
                stageIPA(downloadedURL, takeOwnership: true)
            } catch {
                preflightState = .failed("Could not download the IPA from this URL.")
            }
        }
    }

    // MARK: - Logic

    private func stageIPA(_ source: URL,
                          fallbackToSource: Bool = false,
                          alreadyStaged: Bool = false,
                          takeOwnership: Bool = false) {
        let localURL = alreadyStaged
            ? source
            : (signer.stage(source, takeOwnership: takeOwnership)
               ?? (fallbackToSource ? source : nil))
        guard let localURL else {
            ipaURL = nil
            preflightState = .failed("The IPA could not be copied into iStore storage.")
            return
        }

        ipaURL = localURL
        if !importedAppURLs.contains(where: { $0.path == localURL.path }) {
            importedAppURLs.append(localURL)
        }
        appDisplayName = ""
        bundleId = ""
        appVersion = ""
        selectedIconURL = nil
        signedIPA = nil
        signer.phase = .idle
        preflightState = .inspecting
        let temporaryDirectory = signer.workDir

        Task.detached(priority: .utility) {
            let result = IPAPreflightService.inspect(ipa: localURL,
                                                      temporaryDirectory: temporaryDirectory)
            await MainActor.run {
                guard ipaURL == localURL else { return }
                switch result {
                case .success(let inspection):
                    if appDisplayName.isEmpty { appDisplayName = inspection.appName }
                    if selectedIconURL == nil, let iconURL = inspection.iconURL {
                        selectedIconURL = iconURL
                    }
                    if bundleId.isEmpty { bundleId = inspection.bundleIdentifier }
                    if appVersion.isEmpty { appVersion = inspection.shortVersion }
                    preflightState = .ready(inspection)
                case .failure(let error):
                    preflightState = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func stageDylib(_ source: URL) {
        dylibURL = signer.stage(source, as: source.lastPathComponent)
    }

    private var effectivePassword: String? {
        if let cert = certStore.selected, let saved = certStore.savedPassword(for: cert) {
            return saved
        }
        return password.isEmpty ? nil : password
    }

    private var isSigningConfigurationValid: Bool {
        guard let certificateExpiry = certStore.selected?.notAfter,
              let profileExpiry = profileStore.selected?.notAfter else { return false }
        return certificateExpiry > .now && profileExpiry > .now
    }

    private var canSign: Bool {
        ipaURL != nil && certStore.selected != nil && profileStore.selected != nil && effectivePassword != nil
    }

    private func autoSignDownloadedIPAWhenReady() async {
        // Preflight runs off the main actor. Wait for its result instead of
        // guessing with a fixed delay, otherwise signing can start with an
        // empty bundle ID or display name on slower devices.
        for _ in 0..<600 {
            switch preflightState {
            case .ready:
                autoSignDownloadedIPA()
                return
            case .failed(let message):
                repoStore.completeInstallAttempt(automaticInstallAppID, error: message)
                automaticInstallAppID = nil
                automaticInstallAsAdditionalCopy = false
                signer.phase = .failed(message)
                return
            case .idle, .inspecting:
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let message = localized(
            "IPA inspection timed out. Please try the download again.",
            "انتهت مهلة فحص IPA. حاول تنزيل التطبيق مرة ثانية."
        )
        repoStore.completeInstallAttempt(automaticInstallAppID, error: message)
        automaticInstallAppID = nil
        automaticInstallAsAdditionalCopy = false
        signer.phase = .failed(message)
    }

    private func autoSignDownloadedIPA() {
        // Never expose the manual editor during an automatic GET install.
        showAppEditor = false
        guard ipaURL != nil,
              certStore.selected != nil,
              profileStore.selected != nil,
              effectivePassword != nil else {
            let message = localized(
                "Add a valid certificate, provisioning profile, and P12 password before using GET.",
                "أضف شهادة صالحة وملف حماية وكلمة مرور P12 قبل استخدام زر GET."
            )
            repoStore.completeInstallAttempt(automaticInstallAppID, error: message)
            automaticInstallAppID = nil
            automaticInstallAsAdditionalCopy = false
            signer.phase = .failed(message)
            return
        }
        if automaticInstallAsAdditionalCopy {
            guard let copyIdentifier = additionalCopyIdentifier(from: bundleId) else {
                let message = localized(
                    "Could not create a valid identifier for the additional copy.",
                    "تعذر إنشاء معرّف صالح للنسخة الثانية."
                )
                repoStore.completeInstallAttempt(automaticInstallAppID, error: message)
                automaticInstallAppID = nil
                automaticInstallAsAdditionalCopy = false
                signer.phase = .failed(message)
                return
            }
            // Do not reject a profile based on a local entitlement heuristic.
            // zsign loads the exact profile/certificate pair and returns the
            // authoritative signing error if this generated ID is not allowed.
            bundleId = copyIdentifier
        }
        sign(installAfter: true)
    }

    private func sign(installAfter: Bool = true) {
        guard let ipa = ipaURL,
              let cert = certStore.selected,
              let pw = effectivePassword,
              let profile = profileStore.selected else {
            let message = localized(
                "Add a valid certificate, provisioning profile, and P12 password before using GET.",
                "أضف شهادة صالحة وملف حماية وكلمة مرور P12 قبل استخدام زر GET."
            )
            repoStore.completeInstallAttempt(automaticInstallAppID, error: message)
            automaticInstallAppID = nil
            automaticInstallAsAdditionalCopy = false
            signer.phase = .failed(message)
            return
        }
        let p12 = certStore.fileURL(for: cert)
        let profileFile = profileStore.fileURL(for: profile)
        let certCN = cert.commonName

        signer.phase = .signing
        signedIPA = nil
        lastRecordID = nil
        install.installStatus = ""
        install.installServer?.stop()
        install.installServer = nil
        InstallKeepAlive.shared.stop()
        // Every install attempt gets a fresh output path. Reusing the first
        // signed IPA can make a second install fail after the app was deleted.
        let attemptID = UUID().uuidString.prefix(8)
        let outName = ipa.deletingPathExtension().lastPathComponent + "-signed-\(attemptID).ipa"
        let output = history.signedDir.appendingPathComponent(outName)
        let tempDir = signer.tempDir
        let bid = bundleId.trimmingCharacters(in: .whitespaces)
        let rmExt = removeExtensions
        let enDocs = enableDocuments
        let selectedDylib = dylibURL
        let injectExt = injectIntoExtensions
        let shouldInstall = installAfter

        Task.detached(priority: .userInitiated) {
            // The dylib is now injected inside the signing pass itself, so the
            // IPA is extracted and repacked once instead of twice.
            let result = SigningService.signCached(ipa: ipa, p12: p12, password: pw, profile: profileFile,
                                             bundleId: bid,
                                             displayName: appDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
                                             shortVersion: appVersion.trimmingCharacters(in: .whitespacesAndNewlines),
                                             icon: selectedIconURL,
                                             output: output, tempDir: tempDir,
                                             removeExtensions: rmExt, enableDocuments: enDocs,
                                             dylib: selectedDylib, injectIntoExtensions: injectExt)
            SigningService.trimCache()
            await MainActor.run {
                let signedFileIsValid: Bool = {
                    guard result.ok,
                          FileManager.default.fileExists(atPath: output.path),
                          let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
                          let fileSize = attributes[.size] as? NSNumber else { return false }
                    return fileSize.int64Value > 0
                }()
                if signedFileIsValid {
                    signedIPA = output
                    signedBundleId = result.signedBundleId
                    signedVersion = result.signedVersion
                    signer.phase = .done(localized(
                        "Signed and ready to install.",
                        "تم توقيع التطبيق وتجهيزه للتثبيت."
                    ))
                    showAppEditor = false
                    let record = history.append(inputName: ipa.lastPathComponent,
                                                outputName: outName,
                                                bundleId: result.signedBundleId,
                                                version: result.signedVersion,
                                                certificateCN: certCN)
                    lastRecordID = record.id
                    if shouldInstall {
                        Task { @MainActor in
                            startInstall()
                        }
                    }
                } else {
                    let message = result.ok
                        ? localized(
                            "Signing finished but the signed IPA was not created correctly.",
                            "اكتمل التوقيع لكن ملف IPA الموقّع غير صالح أو غير موجود."
                        )
                        : result.message
                    repoStore.completeInstallAttempt(automaticInstallAppID, error: message)
                    automaticInstallAppID = nil
                    automaticInstallAsAdditionalCopy = false
                    signer.phase = .failed(message)
                }
            }
        }
    }

    private func startInstall() {
        guard let ipa = signedIPA else {
            repoStore.completeInstallAttempt(automaticInstallAppID, error: localized(
                "The signed IPA is unavailable. Please try again.",
                "ملف IPA الموقّع غير متوفر. حاول مرة ثانية."
            ))
            automaticInstallAppID = nil
            automaticInstallAsAdditionalCopy = false
            return
        }
        let recordID = lastRecordID
        if let recordID {
            history.setInstallState(.installing, for: recordID)
        }
        install.onDelivered = {
            if let automaticInstallAppID {
                repoStore.markInstalled(automaticInstallAppID)
                repoStore.completeInstallAttempt(automaticInstallAppID)
                self.automaticInstallAppID = nil
                self.automaticInstallAsAdditionalCopy = false
            }
        }
        let installTitle = appDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ipa.deletingPathExtension().lastPathComponent
            : appDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        install.install(ipa: ipa,
                        bundleId: signedBundleId,
                        version: signedVersion,
                        title: installTitle)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
