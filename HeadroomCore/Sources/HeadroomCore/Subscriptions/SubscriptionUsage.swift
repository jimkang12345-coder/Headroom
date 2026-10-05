import Foundation

public struct QuotaWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let resetText: String?
    public init(id: String, title: String, usedPercent: Double, resetsAt: Date?, resetText: String? = nil) {
        self.id = id; self.title = title; self.usedPercent = usedPercent
        self.resetsAt = Self.usableResetDate(resetsAt); self.resetText = resetText
    }
    public var remainingPercent: Double { max(0, 100 - usedPercent) }

    /// Keep provider and caller-supplied dates within Foundation's conventional
    /// display range before they reach countdowns or date formatters.
    static func usableResetDate(_ date: Date?) -> Date? {
        guard let date, date.timeIntervalSince1970.isFinite,
              date >= .distantPast, date <= .distantFuture else { return nil }
        return date
    }
}

public struct SubscriptionUsage: Equatable, Sendable {
    public let windows: [QuotaWindow]
    public let plan: String?
    public let observedAt: Date
    public let unavailableWindowIDs: [String]
    public var isComplete: Bool { !windows.isEmpty && unavailableWindowIDs.isEmpty }

    public init(windows: [QuotaWindow], plan: String?, observedAt: Date, unavailableWindowIDs: [String] = []) {
        self.windows = windows; self.plan = plan; self.observedAt = observedAt
        self.unavailableWindowIDs = unavailableWindowIDs
    }

    public static func codex(_ data: Data, now: Date = Date()) throws -> Self {
        let result = try JSONDecoder().decode(CodexResponse.self, from: data)
        let buckets = result.rateLimitsByLimitId?.isEmpty == false
            ? result.rateLimitsByLimitId! : result.rateLimits.map { ["codex": $0] } ?? [:]
        var windows: [QuotaWindow] = []
        var unavailable: [String] = []
        for (key, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            if bucket.primary == nil && bucket.secondary == nil { unavailable.append(key) }
            for (slot, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                // Codex slots are optional; only a reported slot can be unusable.
                guard let window else { continue }
                guard let used = window.usedPercent, used.isFinite, (0...100).contains(used) else {
                    unavailable.append("\(key).\(slot)")
                    continue
                }
                let duration = window.windowDurationMins.map { minutes in
                    minutes == 10080 ? "Weekly" : minutes == 300 ? "5-hour" : "\(minutes)-minute"
                } ?? slot.capitalized
                windows.append(QuotaWindow(id: "\(key).\(slot)", title: "\(bucket.limitName ?? key.capitalized) · \(duration)", usedPercent: used, resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:))))
            }
        }
        return Self(windows: windows, plan: buckets["codex"]?.planType ?? buckets.values.first?.planType, observedAt: now, unavailableWindowIDs: unavailable)
    }

    /// Parse only the rendered English usage panel, never cookies or hidden API state.
    public static func claudeWebsite(_ text: String, now: Date = Date()) throws -> Self {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard text.contains("Your usage") || text.contains("Plan usage limits") else {
            throw CocoaError(.coderReadCorrupt)
        }
        func window(labels: [String], id: String, title: String) -> QuotaWindow? {
            guard let start = lines.firstIndex(where: { labels.contains($0) }) else { return nil }
            // A missing percentage must not accidentally consume the next section's value.
            var segment: [String] = []
            let boundaries = ["Current session", "This week", "Weekly limits", "All models", "Sonnet only", "Usage credits", "Extra usage", "This week’s usage by product", "This week's usage by product"]
            var enteredAllModels = lines[start] == "All models"
            for line in lines.dropFirst(start + 1).prefix(8) {
                // The weekly heading may contain an All models subsection.
                // Enter it once, but never borrow another window's percentage.
                if id == "seven_day", line == "All models", !enteredAllModels {
                    enteredAllModels = true
                    continue
                }
                if boundaries.contains(line) { break }
                segment.append(line)
            }
            guard let valueLine = segment.first(where: { $0.range(of: #"^\d+(?:\.\d+)?% used$"#, options: .regularExpression) != nil }),
                  let used = Double(valueLine.replacingOccurrences(of: "% used", with: "")), (0...100).contains(used) else { return nil }
            return QuotaWindow(id: id, title: title, usedPercent: used, resetsAt: nil,
                               resetText: segment.first(where: { $0.hasPrefix("Resets ") }))
        }
        let windows = [
            window(labels: ["Current session"], id: "five_hour", title: "5-hour"),
            window(labels: ["This week", "Weekly limits", "All models"], id: "seven_day", title: "Weekly")
        ].compactMap { $0 }
        guard !windows.isEmpty else {
            throw CocoaError(.coderReadCorrupt)
        }
        let unavailable = ["five_hour", "seven_day"].filter { id in !windows.contains { $0.id == id } }
        return Self(windows: windows, plan: nil, observedAt: now, unavailableWindowIDs: unavailable)
    }

    public static func claude(_ data: Data, now: Date = Date()) throws -> Self {
        let feed = try JSONDecoder().decode(ClaudeFeed.self, from: data)
        let windows = [("five_hour", "5-hour"), ("seven_day", "Weekly")].compactMap { key, title -> QuotaWindow? in
            guard let window = feed.rate_limits?[key], let used = window.used_percentage,
                  used.isFinite, (0...100).contains(used) else { return nil }
            return QuotaWindow(id: key, title: title, usedPercent: used, resetsAt: window.resets_at.map(Date.init(timeIntervalSince1970:)))
        }
        let unavailable = ["five_hour", "seven_day"].filter { id in !windows.contains { $0.id == id } }
        return Self(windows: windows, plan: nil, observedAt: now, unavailableWindowIDs: unavailable)
    }
}

private struct CodexResponse: Decodable {
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?
    struct Bucket: Decodable {
        let limitName: String?
        let planType: String?
        let primary: Window?
        let secondary: Window?
        private enum CodingKeys: String, CodingKey { case limitName, planType, primary, secondary }
        init(from decoder: Decoder) throws {
            let values = try? decoder.container(keyedBy: CodingKeys.self)
            limitName = try? values?.decodeIfPresent(String.self, forKey: .limitName)
            planType = try? values?.decodeIfPresent(String.self, forKey: .planType)
            primary = try values?.decodeIfPresent(Window.self, forKey: .primary)
            secondary = try values?.decodeIfPresent(Window.self, forKey: .secondary)
        }
    }
    struct Window: Decodable {
        let usedPercent: Double?
        let windowDurationMins: Int?
        let resetsAt: Double?
        private enum CodingKeys: String, CodingKey { case usedPercent, windowDurationMins, resetsAt }
        init(from decoder: Decoder) throws {
            let values = try? decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try? values?.decodeIfPresent(Double.self, forKey: .usedPercent)
            windowDurationMins = try? values?.decodeIfPresent(Int.self, forKey: .windowDurationMins)
            resetsAt = try? values?.decodeIfPresent(Double.self, forKey: .resetsAt)
        }
    }
}
private struct ClaudeFeed: Decodable {
    let rate_limits: [String: Window]?
    struct Window: Decodable {
        let used_percentage: Double?
        let resets_at: Double?
        private enum CodingKeys: String, CodingKey { case used_percentage, resets_at }
        init(from decoder: Decoder) throws {
            let values = try? decoder.container(keyedBy: CodingKeys.self)
            used_percentage = try? values?.decodeIfPresent(Double.self, forKey: .used_percentage)
            resets_at = try? values?.decodeIfPresent(Double.self, forKey: .resets_at)
        }
    }
}
