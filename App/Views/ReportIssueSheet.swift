import SwiftUI

/// Composer for a problem report about one catalog app. Reached from the
/// "Report" control at the foot of `RepoAppDetailSheet`.
struct ReportIssueSheet: View {
    let app: RepoApp

    @Environment(\.forgeTheme) private var T
    @Environment(\.dismiss) private var dismiss
    @AppStorage("app.language") private var languageCode = AppLanguage.english.rawValue

    @FocusState private var isEditorFocused: Bool
    @State private var message = ""
    @State private var isSending = false
    @State private var didSend = false
    @State private var failureMessage: String?

    private var isArabic: Bool { languageCode == AppLanguage.arabic.rawValue }
    private var alignment: Alignment { isArabic ? .trailing : .leading }
    private var stackAlignment: HorizontalAlignment { isArabic ? .trailing : .leading }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ForgeBackdrop()
                    .ignoresSafeArea()

                if didSend {
                    confirmation
                } else {
                    composer
                }
            }
        }
        .floatingGlassBackButton(action: { dismiss() })
        // Compact by default; draggable to full height so the composer still
        // has room once the keyboard takes the lower half of the screen.
        .presentationDetents([.height(560), .large])
        .presentationCornerRadius(34)
        .presentationDragIndicator(.hidden)
        .presentationBackground { ForgeBackdrop() }
    }

    // MARK: - Composer

    private var composer: some View {
        ScrollView {
            composerContent
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(localized("Done", "تم")) { isEditorFocused = false }
                    .font(T.sans(15, .semibold))
            }
        }
    }

    private var composerContent: some View {
        VStack(alignment: stackAlignment, spacing: 14) {
            header

            Text(localized("Describe the problem", "اشرح المشكلة"))
                .font(T.sans(13, .semibold))
                .foregroundColor(T.ink3)
                .frame(maxWidth: .infinity, alignment: alignment)

            editor

            if let failureMessage {
                Text(failureMessage)
                    .font(T.sans(12, .medium))
                    .foregroundColor(T.bad)
                    .multilineTextAlignment(isArabic ? .trailing : .leading)
                    .frame(maxWidth: .infinity, alignment: alignment)
            }

            sendButton

            Text(localized(
                "Your app version and device model are attached automatically.",
                "يُرفق إصدار التطبيق ونوع جهازك تلقائيًا مع البلاغ."
            ))
            .font(T.sans(11, .regular))
            .foregroundColor(T.ink3)
            .multilineTextAlignment(isArabic ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: alignment)
        }
        .padding(.horizontal, T.pad + 2)
        .padding(.top, 76)
        .padding(.bottom, 22)
        .environment(\.layoutDirection, isArabic ? .rightToLeft : .leftToRight)
    }

    private var header: some View {
        HStack(spacing: 12) {
            CachedAppIcon(url: app.iconURL, size: 46, cornerRadius: 12)
            VStack(alignment: stackAlignment, spacing: 2) {
                Text(localized("Report an issue", "إبلاغ عن مشكلة"))
                    .font(T.sans(17, .bold))
                    .foregroundColor(T.ink)
                Text(app.name.isEmpty ? "Untitled" : app.name)
                    .font(T.sans(12.5, .medium))
                    .foregroundColor(T.ink3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private var editor: some View {
        ZStack(alignment: isArabic ? .topTrailing : .topLeading) {
            TextEditor(text: $message)
                .focused($isEditorFocused)
                .font(T.sans(14, .regular))
                .foregroundColor(T.ink)
                .multilineTextAlignment(isArabic ? .trailing : .leading)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)

            // TextEditor has no placeholder of its own. This overlays it, so it
            // stays untappable — otherwise it would swallow the tap that puts
            // the cursor in the field.
            if message.isEmpty {
                Text(localized(
                    "Tell us what went wrong — a crash, a wrong version, a broken download…",
                    "اكتب المشكلة التي واجهتك — توقف التطبيق، إصدار خاطئ، تحميل لا يعمل…"
                ))
                .font(T.sans(14, .regular))
                .foregroundColor(T.ink3)
                .multilineTextAlignment(isArabic ? .trailing : .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 17)
                .allowsHitTesting(false)
            }
        }
        .frame(height: 190)
        .glassSurface(.card, cornerRadius: 18)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(T.rule, lineWidth: AppStroke.hairline)
        }
    }

    private var sendButton: some View {
        Button {
            send()
        } label: {
            HStack(spacing: 8) {
                if isSending {
                    ProgressView().tint(T.ink)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(isSending
                     ? localized("Sending…", "جارٍ الإرسال…")
                     : localized("Send", "إرسال"))
                    .font(T.sans(15, .semibold))
            }
            .foregroundColor(T.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .glassSurface(.button, cornerRadius: 16)
        }
        .buttonStyle(GlassTactileButtonStyle())
        .disabled(isSending || trimmedMessage.isEmpty)
        .opacity(isSending || trimmedMessage.isEmpty ? 0.5 : 1)
    }

    // MARK: - Confirmation

    private var confirmation: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundColor(T.good)
            Text(localized("Report sent", "تم إرسال البلاغ"))
                .font(T.sans(18, .bold))
                .foregroundColor(T.ink)
            Text(localized(
                "Thanks — we'll look into it.",
                "شكرًا لك، سنقوم بمراجعة المشكلة."
            ))
            .font(T.sans(13, .regular))
            .foregroundColor(T.ink3)
            .multilineTextAlignment(.center)

            Button {
                dismiss()
            } label: {
                Text(localized("Done", "تم"))
                    .font(T.sans(15, .semibold))
                    .foregroundColor(T.ink)
                    .frame(width: 150)
                    .frame(height: 46)
                    .glassSurface(.button, cornerRadius: 16)
            }
            .buttonStyle(GlassTactileButtonStyle())
            .padding(.top, 6)
        }
        .padding(.horizontal, T.pad + 2)
    }

    // MARK: - Actions

    private func send() {
        let body = trimmedMessage
        guard !body.isEmpty, !isSending else { return }

        isEditorFocused = false
        failureMessage = nil
        isSending = true
        ForgeInteractionFeedback.playLightHaptic()

        Task {
            do {
                try await ReportService.send(message: body, about: app)
                await MainActor.run {
                    isSending = false
                    withAnimation(.easeOut(duration: 0.22)) { didSend = true }
                }
            } catch {
                await MainActor.run {
                    isSending = false
                    failureMessage = localized(
                        "Couldn't send the report. Check your connection and try again.",
                        "تعذّر إرسال البلاغ. تحقق من اتصالك وحاول مرة أخرى."
                    )
                }
            }
        }
    }

    private func localized(_ english: String, _ arabic: String) -> String {
        isArabic ? arabic : english
    }
}
