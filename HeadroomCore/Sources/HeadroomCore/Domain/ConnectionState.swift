import Foundation

public enum UnverifiedReason: String, Codable, Sendable, Hashable {
    case importedFromBackup
    case keyRequiresVerification
    case malformedData
    case unsupportedProvider

    public var description: String {
        switch self {
        case .importedFromBackup:
            return "Imported connection requires local API key setup"
        case .keyRequiresVerification:
            return "API key requires verification"
        case .malformedData:
            return "Provider returned malformed data"
        case .unsupportedProvider:
            return "Provider not supported yet"
        }
    }
}

public enum ConnectionState: Hashable, Codable, Sendable {
    case notConfigured
    case verifying
    case ready
    case awaitingVerification(reason: UnverifiedReason)
    case offline(lastAttempt: Date)
    case timeout
    case rateLimited(retryAfter: Date)
    case authFailed(statusCode: Int)
    case malformedResponse
    case serverError(statusCode: Int)
    case keychainFailure
    case persistenceFailure
    case unavailable

    public var isOperational: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isVerifying: Bool {
        if case .verifying = self { return true }
        return false
    }

    public var isAuthFailed: Bool {
        if case .authFailed = self { return true }
        return false
    }

    public var isRateLimited: Bool {
        if case .rateLimited = self { return true }
        return false
    }

    public var rateLimitDeadline: Date? {
        if case .rateLimited(let deadline) = self { return deadline }
        return nil
    }

    public var statusSummary: String {
        switch self {
        case .notConfigured:
            return "Not Configured"
        case .verifying:
            return "Verifying..."
        case .ready:
            return "Ready"
        case .awaitingVerification(let reason):
            return "Unverified (\(reason.description))"
        case .offline:
            return "Offline"
        case .timeout:
            return "Request Timeout"
        case .rateLimited(let retryAfter):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let relative = formatter.localizedString(for: retryAfter, relativeTo: Date())
            return "Rate Limited (retry \(relative))"
        case .authFailed(let code):
            return "Auth Error (\(code))"
        case .malformedResponse:
            return "Malformed Response"
        case .serverError(let code):
            return "Server Error (\(code))"
        case .keychainFailure:
            return "Keychain Storage Error"
        case .persistenceFailure:
            return "Persistence Error"
        case .unavailable:
            return "Unavailable"
        }
    }
}
