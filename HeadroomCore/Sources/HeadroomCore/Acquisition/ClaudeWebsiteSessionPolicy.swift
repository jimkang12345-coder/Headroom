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
