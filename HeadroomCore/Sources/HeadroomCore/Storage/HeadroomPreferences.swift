import Foundation

public enum HeadroomPreferences {
    // Resolve once so every view and connection store shares the same domain.
    // A DEBUG fixture run must never inherit the regular app's connection flags.
    @MainActor public static let defaults: UserDefaults = {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["HEADROOM_FIXTURE_DIR"], !path.isEmpty {
            return isolatedFixtureDefaults()
        }
        #endif
        return .standard
    }()

    public static func isolatedFixtureDefaults(identifier: UUID = UUID()) -> UserDefaults {
        let domain = "org.headroom.fixture." + identifier.uuidString
        guard let defaults = UserDefaults(suiteName: domain) else {
            preconditionFailure("Unable to isolate fixture preferences")
        }
        // A fresh suite has no regular app settings; writes stay in this fixture domain.
        return defaults
    }
}
