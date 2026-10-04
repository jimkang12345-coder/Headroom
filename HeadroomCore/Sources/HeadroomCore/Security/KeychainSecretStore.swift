import Foundation
import Security

public final class KeychainSecretStore: SecretStoreProtocol, @unchecked Sendable {
    public let serviceName: String

    public init(serviceName: String = "org.headroom.credentials") {
        self.serviceName = serviceName
    }

    public func saveSecret(_ secret: String, for connectionId: ConnectionID) throws {
        guard let data = secret.data(using: .utf8) else {
            throw KeychainError.dataEncodingError
        }

        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: connectionId.uuidString
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        // 1. Attempt SecItemUpdate first to safely replace without deletion
        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        // 2. If item does not exist yet, add it
        if updateStatus == errSecItemNotFound {
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: connectionId.uuidString,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledStatus(addStatus)
            }
            return
        }

        // Any other unexpected status during update
        throw KeychainError.unhandledStatus(updateStatus)
    }

    public func readSecret(for connectionId: ConnectionID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: connectionId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataEncodingError
        }

        return secret
    }

    public func deleteSecret(for connectionId: ConnectionID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: connectionId.uuidString
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandledStatus(status)
        }
    }

    public func hasSecret(for connectionId: ConnectionID) -> Bool {
        (try? readSecret(for: connectionId)) != nil
    }

    public func deleteAllSecrets() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandledStatus(status)
        }
    }
}

public final class InMemorySecretStore: SecretStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConnectionID: String] = [:]
    public var shouldSimulateFailure: Bool = false
    public var failDelete: Bool = false
    public var failSave: Bool = false
    public var failRead: Bool = false

    public init() {}

    public func saveSecret(_ secret: String, for connectionId: ConnectionID) throws {
        lock.lock()
        defer { lock.unlock() }
        if shouldSimulateFailure || failSave {
            throw KeychainError.simulatedFailure
        }
        storage[connectionId] = secret
    }

    public func readSecret(for connectionId: ConnectionID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if shouldSimulateFailure || failRead {
            throw KeychainError.simulatedFailure
        }
        return storage[connectionId]
    }

    public func deleteSecret(for connectionId: ConnectionID) throws {
        lock.lock()
        defer { lock.unlock() }
        if shouldSimulateFailure || failDelete {
            throw KeychainError.simulatedFailure
        }
        storage.removeValue(forKey: connectionId)
    }

    public func hasSecret(for connectionId: ConnectionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[connectionId] != nil
    }

    public func deleteAllSecrets() throws {
        lock.lock()
        defer { lock.unlock() }
        if shouldSimulateFailure || failDelete {
            throw KeychainError.simulatedFailure
        }
        storage.removeAll()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}
