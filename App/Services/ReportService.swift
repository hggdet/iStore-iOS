import Foundation

/// Delivers user-written problem reports from an app's detail page to the
/// catalog maintainers' Telegram chat.
///
/// The bot credentials live in the binary, so treat this bot as public: it may
/// only ever be allowed to *post* into the one maintainer chat below. Anything
/// that would be damaging in a stranger's hands (reading other chats, admin
/// commands) must not be granted to this token — move the call behind a server
/// endpoint first if that ever changes.
enum ReportService {
    private static let botToken = "8965441954:AAE-MWg8Ivv3qXergiMInEs4B0zokHWHEo4"
    private static let chatID = "1534238239"

    /// Telegram rejects anything past 4096 UTF-16 units; leave room for the
    /// metadata header we prepend.
    private static let maxUserMessageLength = 3000

    enum ReportError: LocalizedError {
        case emptyMessage
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .emptyMessage: return "The report is empty."
            case .transport(let detail): return detail
            }
        }
    }

    /// Posts one report and returns once Telegram has accepted it.
    static func send(message: String, about app: RepoApp) async throws {
        let body = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ReportError.emptyMessage }

        let text = compose(message: String(body.prefix(maxUserMessageLength)), about: app)

        var request = URLRequest(url: URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 25
        // Plain text on purpose: user prose would otherwise have to be escaped
        // against Telegram's Markdown/HTML parsers, and a stray "*" or "<"
        // would fail the whole send.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "chat_id": chatID,
            "text": text,
            "disable_web_page_preview": true
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ReportError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let described = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = described?["description"] as? String
            throw ReportError.transport(detail ?? "Telegram returned HTTP \(status).")
        }
    }

    /// Report body: what was reported, which build it was reported from, and
    /// enough device context to reproduce it — the reporter shouldn't have to
    /// type any of that themselves.
    private static func compose(message: String, about app: RepoApp) -> String {
        var lines = ["🐞 iStore — app report", ""]
        lines.append("App: \(app.name.isEmpty ? "Untitled" : app.name)")
        if !app.bundleIdentifier.isEmpty {
            lines.append("Bundle: \(app.bundleIdentifier)")
        }
        if let version = app.version, !version.isEmpty {
            lines.append("Version: \(version)")
        }
        if let category = app.category, !category.isEmpty {
            lines.append("Category: \(category)")
        }
        lines.append("Device: \(deviceSummary)")
        lines.append("Sent: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("Message:")
        lines.append(message)
        return lines.joined(separator: "\n")
    }

    /// Deliberately free of `UIDevice`: UIKit is main-actor isolated, and this
    /// runs on whatever thread the send happens to be on.
    private static var deviceSummary: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let build = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "\(hardwareIdentifier) · iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · iStore \(build)"
    }

    /// `UIDevice.model` only ever says "iPhone"; the machine identifier
    /// ("iPhone16,2") is what actually distinguishes one report from another.
    private static var hardwareIdentifier: String {
        var info = utsname()
        uname(&info)
        let identifier = withUnsafeBytes(of: &info.machine) { raw in
            raw.prefix { $0 != 0 }.map { String(UnicodeScalar($0)) }.joined()
        }
        return identifier.isEmpty ? "unknown device" : identifier
    }
}
