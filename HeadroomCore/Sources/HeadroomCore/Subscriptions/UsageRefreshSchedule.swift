import Foundation

/// One request at a time, bounded automatic retries, and a manual-refresh throttle.
public struct UsageRefreshSchedule: Sendable {
    /// Automatic checks run once a minute; failures back off from there, never faster.
    public static let interval: TimeInterval = 60
    public private(set) var nextAttempt: Date = .distantPast
    public private(set) var lastStarted: Date = .distantPast
    public private(set) var failures = 0
    public private(set) var inFlight = false
    public init() {}

    public mutating func begin(at now: Date, forced: Bool = false) -> Bool {
        guard !inFlight, now.timeIntervalSince(lastStarted) >= 3,
              forced || now >= nextAttempt else { return false }
        inFlight = true
        lastStarted = now
        return true
    }
    public mutating func finish(at now: Date, succeeded: Bool) {
        inFlight = false
        failures = succeeded ? 0 : min(failures + 1, 5)
        let delay = succeeded ? Self.interval : min(300, Self.interval * pow(2, Double(failures - 1)))
        // Successful cadence is measured from start; latency does not add another interval.
        nextAttempt = succeeded ? max(now, lastStarted.addingTimeInterval(delay)) : now.addingTimeInterval(delay)
    }
    public mutating func resume() { nextAttempt = .distantPast }
}
