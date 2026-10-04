import Foundation

public enum DeepSeekError: Error, LocalizedError, Equatable {
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
    case missingRequiredField(field: String)
    case invalidResponseFormat
    case networkError

    public var errorDescription: String? {
        switch self {
        case .authFailure(let code):
            return "Authentication failed (HTTP \(code)). Please check your API key."
        case .rateLimited(let date):
            let formatter = ISO8601DateFormatter()
            return "Rate limited until \(formatter.string(from: date))."
        case .serverError(let code):
            return "DeepSeek server error (HTTP \(code))."
        case .offline:
            return "Network connection unavailable."
        case .timeout:
            return "Request timed out."
        case .cancelled:
            return "Request cancelled."
        case .redirectRejected:
            return "Unexpected redirect was rejected for security."
        case .invalidHost:
            return "Invalid endpoint host."
        case .responseTooLarge:
            return "Response exceeded maximum safe size (64 KB)."
        case .malformedResponse:
            return "Malformed response payload from provider."
        case .missingRequiredField(let field):
            return "Response missing required field: \(field)."
        case .invalidResponseFormat:
            return "Invalid response format received from server."
        case .networkError:
            return "Network transport error."
        }
    }
}

public struct RawBalanceInfo: Codable, Sendable {
    public let currency: String?
    public let total_balance: String?
    public let granted_balance: String?
    public let topped_up_balance: String?

    public init(
        currency: String?,
        total_balance: String?,
        granted_balance: String?,
        topped_up_balance: String?
    ) {
        self.currency = currency
        self.total_balance = total_balance
        self.granted_balance = granted_balance
        self.topped_up_balance = topped_up_balance
    }
}

public struct RawDeepSeekResponse: Codable, Sendable {
    public let is_available: Bool?
    public let balance_infos: [RawBalanceInfo]?

    public init(is_available: Bool?, balance_infos: [RawBalanceInfo]?) {
        self.is_available = is_available
        self.balance_infos = balance_infos
    }
}
