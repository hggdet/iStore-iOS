import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct URLImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.forgeTheme) private var T

    @Binding var urlText: String
    let isLoading: Bool
    let importAction: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("IPA URL")
                        .font(T.sans(14, .semibold))
                        .foregroundColor(T.ink)
                    TextField("https://…", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .padding(.horizontal, 14)
                        .frame(height: 50)
                        .glassSurface(.button, cornerRadius: 15)
                        .overlay {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(T.rule, lineWidth: AppStroke.hairline)
                        }
                }

                Button(action: importAction) {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView().tint(T.ink)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                        }
                        Text(isLoading ? "Downloading…" : "Import")
                            .font(T.sans(15, .semibold))
                    }
                    .foregroundColor(T.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .glassSurface(.button, cornerRadius: 16)
                }
                .buttonStyle(GlassTactileButtonStyle())
                .disabled(isLoading || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding(20)
            .background { ForgeBackdrop() }
            .navigationTitle("Import URL")
            .navigationBarTitleDisplayMode(.inline)
        }
        .floatingGlassBackButton(action: { dismiss() })
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
        .onChange(of: isLoading) { nowLoading in
            if !nowLoading {
                dismiss()
            }
        }
    }
}

struct AppEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.forgeTheme) private var T

    @Binding var appName: String
    @Binding var bundleID: String
    @Binding var version: String
    @Binding var password: String
    let hasSavedPassword: Bool
    let certificateName: String?
    let profileName: String?
    let preflightState: IPAPreflightState
    let isSigning: Bool
    let canSign: Bool
    let dylibURL: URL?
    let iconURL: URL?
    let shareURL: URL?
    @Binding var removeExtensions: Bool
    @Binding var enableDocuments: Bool
    let onChooseIcon: (URL) -> Void
    let onChoosePhoto: (PhotosPickerItem?) -> Void
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showIconDocumentPicker = false
    @State private var showDylibFileImporter = false
    @State private var showShareSheet = false
    @State private var showShareError = false
    let onChooseCertificate: () -> Void
    let onChooseProfile: () -> Void
    let onChooseDylib: (URL) -> Void
    let onRemoveDylib: () -> Void
    let onSignOnly: () -> Void
    let onSign: () -> Void
    @State private var showExtensionAlert = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    iconButton
                    editFields
                    signingAssets
                    toolsSection
                    signingOptions
                    signButton
                }
                .padding(.top, 18)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .background { ForgeBackdrop() }
            .navigationTitle(appName.isEmpty ? "Application" : appName)
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showIconDocumentPicker) {
            ForgeDocumentPicker(contentTypes: [.image], onPick: { urls in
                showIconDocumentPicker = false
                guard let url = urls.first else { return }
                onChooseIcon(url)
            }, onCancel: {
                showIconDocumentPicker = false
            })
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showDylibFileImporter,
                      allowedContentTypes: [UTType(filenameExtension: "dylib") ?? .data]) { result in
            if case .success(let url) = result {
                onChooseDylib(url)
            }
        }
        .floatingGlassBackButton(action: { dismiss() })
        .sheet(isPresented: $showShareSheet) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .alert("IPA unavailable", isPresented: $showShareError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Sign or import an IPA before sharing it.")
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: selectedPhoto) { item in
            onChoosePhoto(item)
        }
    }

    private var iconButton: some View {
        VStack(spacing: 10) {
            Group {
                if let iconURL, let image = UIImage(contentsOfFile: iconURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundColor(T.accent2)
                }
            }
            .frame(width: 92, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassSurface(.card, cornerRadius: 24)
            .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(T.rule, lineWidth: AppStroke.hairline)
                }

            Text("Change Icon")
                .font(T.sans(13, .medium))
                .foregroundColor(T.ink2)

            HStack(spacing: 10) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .font(T.sans(13, .semibold))
                        .foregroundColor(T.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        // Same glass surface as the Files button beside it —
                        // a bare material here made the pair render as two
                        // different kinds of control.
                        .glassSurface(.button, cornerRadius: 14)
                }
                .buttonStyle(GlassTactileButtonStyle())

                Button { showIconDocumentPicker = true } label: {
                    Label("Files", systemImage: "folder")
                        .font(T.sans(13, .semibold))
                        .foregroundColor(T.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .glassSurface(.button, cornerRadius: 14)
                }
                .buttonStyle(GlassTactileButtonStyle())
            }
        }
        .padding(.horizontal, T.pad)
    }

    private var editFields: some View {
        VStack(spacing: 0) {
            GlassInputRow(icon: "textformat", label: "App Name", placeholder: "Application name", text: $appName)
            GlassRowDivider()
            GlassInputRow(icon: "curlybraces", label: "Bundle ID", placeholder: "com.example.app", text: $bundleID)
            GlassRowDivider()
            GlassInputRow(icon: "number", label: "Version", placeholder: "1.0", text: $version)
        }
        .glassSurface(.card, cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
    }

    private var signingAssets: some View {
        VStack(spacing: 0) {
            GlassSecondaryButton(label: certificateName == nil ? "Certificate (.p12)" : certificateName!, systemImage: "key.fill") {
                onChooseCertificate()
            }
            GlassRowDivider()
            GlassSecondaryButton(label: profileName == nil ? "Provisioning Profile" : profileName!, systemImage: "checkmark.seal.fill") {
                onChooseProfile()
            }
            if !hasSavedPassword {
                GlassRowDivider()
                GlassInputRow(icon: "lock.fill", label: "P12 Password", placeholder: "Required", text: $password, isSecure: true)
            }
        }
        .glassSurface(.card, cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
    }

    private var toolsSection: some View {
        VStack(spacing: 0) {
            GlassSecondaryButton(label: dylibURL == nil ? "Add Dylib" : "Dylib Added", systemImage: "puzzlepiece.extension") {
                showDylibFileImporter = true
            }
            if dylibURL != nil {
                GlassRowDivider()
                GlassSecondaryButton(label: "Remove Dylib", systemImage: "minus.circle", destructive: true) {
                    onRemoveDylib()
                }
            }
            GlassRowDivider()
            GlassSecondaryButton(label: "Share IPA", systemImage: "square.and.arrow.up") {
                guard let shareURL, FileManager.default.fileExists(atPath: shareURL.path) else {
                    showShareError = true
                    return
                }
                showShareSheet = true
            }
            GlassRowDivider()
            GlassSecondaryButton(label: removeExtensions ? "Extensions Will Be Removed" : "Remove App Extensions", systemImage: "rectangle.badge.minus") {
                showExtensionAlert = true
            }
        }
        .glassSurface(.card, cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
        .alert("Remove App Extensions?", isPresented: $showExtensionAlert) {
            Button("Remove", role: .destructive) { removeExtensions = true }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("App extensions will be removed while the IPA is signed.")
        }
    }

    private var signingOptions: some View {
        VStack(spacing: 0) {
            GlassToggleRow(label: "Enable Files import / sharing", isOn: $enableDocuments)
        }
        .glassSurface(.card, cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
        .padding(.horizontal, T.pad)
    }

    private var signButton: some View {
        HStack(spacing: 10) {
            actionButton(title: "Sign Only", icon: "signature", action: onSignOnly)
            actionButton(title: "Sign & Install", icon: "arrow.down.app", action: onSign)
        }
        .disabled(!canSign || isSigning)
        .opacity(canSign && !isSigning ? 1 : 0.45)
        .padding(.horizontal, T.pad)
    }

    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isSigning { ProgressView().tint(T.ink) }
                Image(systemName: icon)
                Text(isSigning ? LocalizedStringKey("Signing…") : LocalizedStringKey(title))
                    .font(T.sans(14, .semibold))
            }
            .foregroundColor(T.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .glassSurface(.button, cornerRadius: 17)
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(T.rule2, lineWidth: AppStroke.hairline)
            }
        }
        .buttonStyle(GlassTactileButtonStyle())
    }
}
