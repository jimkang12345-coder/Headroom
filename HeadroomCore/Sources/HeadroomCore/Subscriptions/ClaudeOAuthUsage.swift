import CryptoKit
import Foundation

/// Keychain service Claude Code uses for one config directory.
public enum ClaudeCredentialLocator {
    public static let defaultService = "Claude Code-credentials"

    /// The default `~/.claude` directory keeps the unsuffixed service. Every other directory
    /// uses the first 8 hex characters of SHA-256 over that directory's path.
    public static func service(configDirectory: URL, defaultDirectory: URL) -> String {
        let config = configDirectory.standardizedFileURL.path
        let standard = defaultDirectory.standardizedFileURL.path
        guard config != standard else { return defaultService }
        let digest = SHA256.hash(data: Data(config.utf8))
        let prefix = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "\(defaultService)-\(prefix)"
    }
}

extension SubscriptionUsage {
    /// Parse `GET /api/oauth/usage`. `utilization` and `limits[].percent` are already 0–100.
    public static func claudeOAuth(_ data: Data, now: Date = Date()) throws -> Self {
        let payload = try JSONDecoder().decode(ClaudeOAuthBody.self, from: data)
        let session = window("five_hour", title: "5-hour", kind: "session", body: payload)
        let weekly = window("seven_day", title: "Weekly", kind: "weekly_all", body: payload)
        let windows = [session, weekly].compactMap { $0 }
        let unavailable = [
            session == nil ? "five_hour" : nil,
            weekly == nil ? "seven_day" : nil
        ].compactMap { $0 }
        return Self(windows: windows, plan: nil, observedAt: now, unavailableWindowIDs: unavailable)
    }

    private static func window(_ id: String, title: String, kind: String, body: ClaudeOAuthBody) -> QuotaWindow? {
        if let row = body.limits?.first(where: { $0.kind == kind }),
           let used = usablePercent(row.percent) {
            return QuotaWindow(id: id, title: title, usedPercent: used, resetsAt: date(row.resets_at))
        }
        let fallback = id == "five_hour" ? body.five_hour : body.seven_day
        guard let used = usablePercent(fallback?.utilization) else { return nil }
        return QuotaWindow(id: id, title: title, usedPercent: used, resetsAt: date(fallback?.resets_at))
    }

    private static func usablePercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private static func date(_ value: ClaudeOAuthInstant?) -> Date? {
        switch value {
        case .seconds(let seconds):
            return Date(timeIntervalSince1970: seconds)
        case .text(let text):
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: text)
        case nil:
            return nil
        }
    }
}

private struct ClaudeOAuthBody: Decodable {
    let five_hour: ClaudeOAuthWindow?
    let seven_day: ClaudeOAuthWindow?
    let limits: [ClaudeOAuthLimit]?
}

private struct ClaudeOAuthWindow: Decodable {
    let utilization: Double?
    let resets_at: ClaudeOAuthInstant?
}

private struct ClaudeOAuthLimit: Decodable {
    let kind: String?
    let percent: Double?
    let resets_at: ClaudeOAuthInstant?
}

private enum ClaudeOAuthInstant: Decodable {
    case seconds(Double)
    case text(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            self = .seconds(seconds)
            return
        }
        self = .text(try container.decode(String.self))
    }
}
