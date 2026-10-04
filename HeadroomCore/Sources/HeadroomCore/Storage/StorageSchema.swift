import Foundation

public enum StorageBlockedReason: Equatable, Sendable, Codable {
    case unsupportedSchemaVersion(Int)
    case corruptData(String)
    case corruptPreservationFailed(String)
    case readFailed(String)
    case recoveryJournalUnreadable

    public var localizedDescription: String {
        switch self {
        case .recoveryJournalUnreadable:
            return "Recovery records could not be opened. Keep the saved files and try loading again."
        case .unsupportedSchemaVersion(let v):
            return "Saved data version \(v) is unsupported by this version of Headroom."
        case .corruptData(let msg):
            return "Saved data is corrupted: \(msg)"
        case .corruptPreservationFailed(let msg):
            return "Failed to preserve corrupted data backup: \(msg)"
        case .readFailed(let msg):
            return "Failed to read storage: \(msg)"
        }
    }
}

public enum StorageStatus: Equatable, Sendable, CustomStringConvertible {
    case uninitialized
    case healthy
    case blocked(StorageBlockedReason)

    public var description: String {
        switch self {
        case .uninitialized:
            return "Uninitialized"
        case .healthy:
            return "Healthy"
        case .blocked(let reason):
            return reason.localizedDescription
        }
    }
}

public struct PendingOperationIntent: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case add
        case replaceCredential
        case delete
    }

    public enum Stage: String, Codable, Sendable {
        case initiated
        case credentialWritten
        case metadataCommitted
        case compensationFailed
        case cleanupFailed
    }

    public let id: UUID
    public let connectionId: ConnectionID
    public let generationId: ConnectionGenerationID
    public let credentialId: ConnectionID
    public let oldCredentialId: ConnectionID?
    public let kind: Kind
    public var stage: Stage
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        connectionId: ConnectionID,
        generationId: ConnectionGenerationID,
        credentialId: ConnectionID,
        oldCredentialId: ConnectionID? = nil,
        kind: Kind,
        stage: Stage = .initiated,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.connectionId = connectionId
        self.generationId = generationId
        self.credentialId = credentialId
        self.oldCredentialId = oldCredentialId
        self.kind = kind
        self.stage = stage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StoredData: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var connections: [Connection]
    public var observations: [WalletObservation]
    public var pendingIntents: [PendingOperationIntent]
    public var updatedAt: Date

    public init(
        version: Int = StoredData.currentVersion,
        connections: [Connection] = [],
        observations: [WalletObservation] = [],
        pendingIntents: [PendingOperationIntent] = [],
        updatedAt: Date = Date()
    ) {
        self.version = version
        self.connections = connections
        self.observations = observations
        self.pendingIntents = pendingIntents
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case version
        case connections
        case observations
        case pendingIntents
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.connections = try container.decode([Connection].self, forKey: .connections)
        self.observations = try container.decode([WalletObservation].self, forKey: .observations)
        self.pendingIntents = try container.decodeIfPresent([PendingOperationIntent].self, forKey: .pendingIntents) ?? []
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
