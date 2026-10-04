import Foundation

public protocol SecretStoreProtocol: Sendable {
    func saveSecret(_ secret: String, for connectionId: ConnectionID) throws
    func readSecret(for connectionId: ConnectionID) throws -> String?
    func deleteSecret(for connectionId: ConnectionID) throws
    func hasSecret(for connectionId: ConnectionID) -> Bool
    func deleteAllSecrets() throws
}

public enum KeychainError: Error, LocalizedError, Equatable {
    case duplicateItem
    case itemNotFound
    case unhandledStatus(OSStatus)
    case dataEncodingError
    case simulatedFailure

    public var errorDescription: String? {
        switch self {
        case .duplicateItem:
            return "Secret already exists for this connection."
        case .itemNotFound:
            return "No secret found for this connection."
        case .unhandledStatus(let status):
            return "Keychain operation failed with status \(status)."
        case .dataEncodingError:
            return "Failed to encode/decode secret data."
        case .simulatedFailure:
            return "Simulated secret store failure for testing."
        }
    }
}
