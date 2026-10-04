import Foundation

/// Clearly labeled, offline quota samples. Capture an anchor once per preview session.
public enum SubscriptionFixtures {
    public static func codex(at anchor: Date) -> SubscriptionUsage {
        SubscriptionUsage(windows: [
            QuotaWindow(id: "codex.primary", title: "Codex · 5-hour", usedPercent: 32, resetsAt: anchor.addingTimeInterval(3 * 3600)),
            QuotaWindow(id: "codex.secondary", title: "Codex · Weekly", usedPercent: 54, resetsAt: anchor.addingTimeInterval(4 * 86400))
        ], plan: "Synthetic sample", observedAt: anchor)
    }

    public static func claudeCode(at anchor: Date) -> SubscriptionUsage {
        SubscriptionUsage(windows: [
            QuotaWindow(id: "five_hour", title: "5-hour", usedPercent: 41, resetsAt: anchor.addingTimeInterval(2 * 3600)),
            QuotaWindow(id: "seven_day", title: "Weekly", usedPercent: 23, resetsAt: anchor.addingTimeInterval(5 * 86400))
        ], plan: "Synthetic sample", observedAt: anchor)
    }
}
