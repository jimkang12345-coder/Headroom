import Foundation

public enum QuotaPresentation {
    public struct MenuBarItems: Equatable, Sendable {
        public let codex: Bool
        public let claude: Bool
        /// A neutral item keeps Headroom reachable when no subscription is connected.
        public var fallback: Bool { !codex && !claude }
        public init(codex: Bool, claude: Bool) {
            self.codex = codex
            self.claude = claude
        }
    }

    /// Disconnected subscriptions get no menu bar item; synthetic samples show both.
    public static func menuBarItems(codexConnected: Bool, claudeConnected: Bool, synthetic: Bool) -> MenuBarItems {
        MenuBarItems(codex: synthetic || codexConnected, claude: synthetic || claudeConnected)
    }

    /// Show a requested window, or the window closest to exhaustion; unknown usage stays unknown.
    public static func menuPercentage(_ usage: SubscriptionUsage?, windowID: String? = nil) -> String {
        let selected: QuotaWindow?
        if let windowID {
            selected = usage?.windows.first(where: { $0.id == windowID })
        } else {
            guard usage?.isComplete == true else { return "—" }
            selected = usage?.windows.max(by: { $0.usedPercent < $1.usedPercent })
        }
        guard let window = selected, window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else { return "—" }
        return String(format: "%.0f%%", window.remainingPercent)
    }

    public static func countdown(_ window: QuotaWindow, observedAt: Date, now: Date, calendar: Calendar = .current) -> String {
        guard QuotaWindow.usableResetDate(now) != nil else { return "Reset time unavailable" }
        let inferred = window.resetsAt == nil
        guard let reset = window.resetsAt ?? websiteReset(window.resetText, observedAt: observedAt, calendar: calendar) else {
            return window.resetText ?? "Reset time unavailable"
        }
        if inferred, window.id == "five_hour", reset.timeIntervalSince(observedAt) > 5 * 3600 + 60 {
            return "Reset time awaiting update"
        }
        let seconds = reset.timeIntervalSince(now)
        guard seconds.isFinite else { return "Reset time unavailable" }
        guard seconds > 0 else { return "Reset due · awaiting update" }
        guard let minutes = Int(exactly: ceil(seconds / 60)) else { return "Reset time unavailable" }
        let days = minutes / 1440, hours = (minutes % 1440) / 60, mins = minutes % 60
        let duration: String
        if days > 0 { duration = "\(days)d \(hours)h" }
        else if hours > 0 { duration = "\(hours)h \(mins)m" }
        else { duration = "\(mins)m" }
        return "Resets in \(inferred ? "≈" : "")\(duration)"
    }

    /// Website reset wording is in the local browser timezone. Anchor once to the
    /// observation time so stale data cannot silently roll to tomorrow/next week.
    public static func websiteReset(_ text: String?, observedAt: Date, calendar: Calendar = .current) -> Date? {
        guard let text, QuotaWindow.usableResetDate(observedAt) != nil else { return nil }
        let normalized = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let pattern = #"^Resets (?:(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday) (?:at )?|at )(\d{1,2}):(\d{2}) (AM|PM)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: normalized) else { return nil }
            return String(normalized[range])
        }
        guard let rawHour = group(2).flatMap(Int.init), (1...12).contains(rawHour),
              let minute = group(3).flatMap(Int.init), (0...59).contains(minute) else { return nil }
        let hour = rawHour % 12 + (group(4) == "PM" ? 12 : 0)
        var components = DateComponents(hour: hour, minute: minute, second: 0)
        if let day = group(1) {
            components.weekday = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"].firstIndex(of: day).map { $0 + 1 }
        }
        return QuotaWindow.usableResetDate(calendar.nextDate(after: observedAt.addingTimeInterval(-1), matching: components, matchingPolicy: .nextTime, repeatedTimePolicy: .first))
    }
}
