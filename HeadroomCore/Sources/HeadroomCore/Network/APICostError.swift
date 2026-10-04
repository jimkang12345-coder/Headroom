import Foundation

/// Sanitized diagnostics shared by organization reporting clients.
public enum APICostError: Error, LocalizedError, Equatable, Sendable {
    case authFailure(statusCode: Int)
    case rateLimited(retryAfter: Date)
    case serverError(statusCode: Int)
    case offline
    case timeout
    case cancelled
    case redirectRejected
    case invalidHost
    case responseTooLarge
    case malformedResponse
    case incompleteReport
    case networkError

    public var errorDescription: String? {
        switch self {
        case .authFailure(let code):
            return "Organization reporting access failed (HTTP \(code)). Check the Admin API key and organization permissions."
        case .rateLimited:
            return "Organization reporting is rate limited. Retry after the displayed deadline."
        case .serverError(let code):
            return "The reporting service returned HTTP \(code)."
        case .offline: return "Network connection unavailable."
        case .timeout: return "Organization reporting request timed out."
        case .cancelled: return "Organization reporting request cancelled."
        case .redirectRejected: return "An unexpected reporting redirect was rejected."
        case .invalidHost: return "An unexpected reporting endpoint was rejected."
        case .responseTooLarge: return "Organization reporting exceeded the safe response size."
        case .malformedResponse: return "The provider returned an unsupported or malformed cost report."
        case .incompleteReport: return "The cost report could not be completed. No partial total was saved."
        case .networkError: return "Organization reporting transport failed."
        }
    }
}
