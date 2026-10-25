import Foundation

/// Navigation boundary for the dedicated Claude account window.
/// This controls page navigation, not the website's subresource requests.
public enum ClaudeWebsiteNavigationPolicy {
    public static func allows(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "claude.ai",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return false }
        return true
    }

    public static func isUsagePage(_ url: URL?) -> Bool {
        guard allows(url), let url else { return false }
        return url.path == "/settings/usage" || url.fragment == "settings/usage"
    }
}

/// Paces reloads of the account usage page. Every wait has a deadline, so a suspended page,
/// an unanswered script or a route away from the usage page delays readings instead of ending them.
public struct ClaudeWebsiteRefreshSchedule: Sendable {
    public enum Step: Equatable, Sendable { case wait, read, reload, timedOut }
    public private(set) var failures = 0
    public private(set) var nextLoad: Date = .distantPast
    private var lastLoad: Date = .distantPast
    private var awaitingSnapshot = false
    private var readStarted: Date?
    public init() {}

    /// `signingIn` means the connection window is on screen, so another claude.ai page may be a sign-in form.
    public mutating func next(at now: Date, isLoading: Bool, onUsagePage: Bool, signingIn: Bool, forced: Bool = false) -> Step {
        if let readStarted {
            guard now.timeIntervalSince(readStarted) > 10 else { return .wait }
            self.readStarted = nil
        }
        if awaitingSnapshot {
            guard now.timeIntervalSince(lastLoad) <= 25 else {
                fail(at: now)
                return .timedOut
            }
            return isLoading || !onUsagePage ? .wait : .read
        }
        // Don't reload a sign-in form while the user is entering credentials.
        if signingIn && !onUsagePage { return .wait }
        return now >= nextLoad || (forced && now.timeIntervalSince(lastLoad) >= 5) ? .reload : .wait
    }
    public mutating func beginLoad(at now: Date) {
        lastLoad = now
        awaitingSnapshot = true
        readStarted = nil
    }
    public mutating func finishLoad(onUsagePage: Bool, signingIn: Bool, at now: Date) {
        if onUsagePage {
            // React may not have rendered yet; reads repeat within the load deadline.
            awaitingSnapshot = true
            lastLoad = now
        } else {
            awaitingSnapshot = false
            if !signingIn { fail(at: now) }
        }
    }
    public mutating func beginRead(at now: Date) { readStarted = now }
    public mutating func finishRead(succeeded: Bool, at now: Date) {
        readStarted = nil
        guard succeeded else { return }
        awaitingSnapshot = false
        failures = 0
        nextLoad = now.addingTimeInterval(30)
    }
    public mutating func fail(at now: Date) {
        awaitingSnapshot = false
        readStarted = nil
        failures = min(failures + 1, 4)
        nextLoad = now.addingTimeInterval(min(300, 30 * pow(2, Double(failures))))
    }
    public mutating func pause() {
        awaitingSnapshot = false
        readStarted = nil
    }
    public mutating func resume() {
        pause()
        nextLoad = .distantPast
    }
}

/// Invalidates outstanding readings when a session pauses or is deleted.
/// A failed deletion keeps reconnection blocked until deletion succeeds.
public struct ClaudeWebsiteSessionLifecycle: Sendable {
    public private(set) var enabled = false
    public private(set) var epoch: UInt64 = 0
    public private(set) var isDeleting = false
    public private(set) var deletionRequired = false

    public init() {}

    @discardableResult
    public mutating func setEnabled(_ value: Bool) -> Bool {
        guard enabled != value,
              !value || (!isDeleting && !deletionRequired) else { return false }
        enabled = value
        epoch &+= 1
        return true
    }

    public mutating func beginDeletion() {
        enabled = false
        epoch &+= 1
        isDeleting = true
        deletionRequired = true
    }

    public mutating func finishDeletion(succeeded: Bool) {
        isDeleting = false
        deletionRequired = !succeeded
    }

    public func acceptsReading(from expectedEpoch: UInt64) -> Bool {
        enabled && !isDeleting && !deletionRequired && epoch == expectedEpoch
    }
}
