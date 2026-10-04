import Foundation

public struct SnapshotDTO: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let exportedAt: Date
    public let connections: [ConnectionSnapshotDTO]
    public let observations: [ObservationSnapshotDTO]

    public init(
        schemaVersion: Int = SnapshotDTO.currentSchemaVersion,
        exportedAt: Date = Date(),
        connections: [ConnectionSnapshotDTO],
        observations: [ObservationSnapshotDTO]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.connections = connections
        self.observations = observations
    }

    public static func from(connections: [Connection], observations: [WalletObservation]) -> SnapshotDTO {
        let connDTOs = connections.map { ConnectionSnapshotDTO(from: $0) }
        let obsDTOs = observations.map { ObservationSnapshotDTO(from: $0) }
        return SnapshotDTO(
            schemaVersion: currentSchemaVersion,
            exportedAt: Date(),
            connections: connDTOs,
            observations: obsDTOs
        )
    }
}

public struct ConnectionSnapshotDTO: Codable, Sendable, Equatable {
    public let id: String
    public let providerId: String
    public let userLabel: String
    public let createdAt: Date
    public let updatedAt: Date
    public let lastAttemptedRefresh: Date?
    public let lastSuccessfulRefresh: Date?
    public let stateSummary: String
    public let monthlyBudget: String?
    public let apiCost: APICostObservation?

    public init(from connection: Connection) {
        self.id = connection.id.uuidString
        self.providerId = connection.providerId.rawValue
        self.userLabel = connection.userLabel
        self.createdAt = connection.createdAt
        self.updatedAt = connection.updatedAt
        self.lastAttemptedRefresh = connection.lastAttemptedRefresh
        self.lastSuccessfulRefresh = connection.lastSuccessfulRefresh
        self.stateSummary = connection.state.statusSummary
        self.monthlyBudget = connection.monthlyBudget.map { NSDecimalNumber(decimal: $0).stringValue }
        self.apiCost = connection.lastAPICostObservation
    }

    public init(
        id: String,
        providerId: String,
        userLabel: String,
        createdAt: Date,
        updatedAt: Date,
        lastAttemptedRefresh: Date?,
        lastSuccessfulRefresh: Date?,
        stateSummary: String,
        monthlyBudget: String? = nil,
        apiCost: APICostObservation? = nil
    ) {
        self.id = id
        self.providerId = providerId
        self.userLabel = userLabel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAttemptedRefresh = lastAttemptedRefresh
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
        self.stateSummary = stateSummary
        self.monthlyBudget = monthlyBudget
        self.apiCost = apiCost
    }
}

public struct ObservationSnapshotDTO: Codable, Sendable, Equatable {
    public let id: String
    public let connectionId: String
    public let isAvailable: Bool
    public let balances: [CurrencyBalanceSnapshotDTO]
    public let capturedAt: Date

    public init(from observation: WalletObservation) {
        self.id = observation.id.uuidString
        self.connectionId = observation.connectionId.uuidString
        self.isAvailable = observation.isAvailable
        self.balances = observation.balances.map { CurrencyBalanceSnapshotDTO(from: $0) }
        self.capturedAt = observation.capturedAt
    }

    public init(
        id: String,
        connectionId: String,
        isAvailable: Bool,
        balances: [CurrencyBalanceSnapshotDTO],
        capturedAt: Date
    ) {
        self.id = id
        self.connectionId = connectionId
        self.isAvailable = isAvailable
        self.balances = balances
        self.capturedAt = capturedAt
    }
}

public struct CurrencyBalanceSnapshotDTO: Codable, Sendable, Equatable {
    public let currency: String
    public let totalBalance: String
    public let grantedBalance: String
    public let toppedUpBalance: String

    public init(from balance: CurrencyBalance) {
        self.currency = balance.currency
        self.totalBalance = balance.rawTotal
        self.grantedBalance = balance.rawGranted
        self.toppedUpBalance = balance.rawToppedUp
    }

    public init(currency: String, total: String, granted: String, toppedUp: String) {
        self.currency = currency
        self.totalBalance = total
        self.grantedBalance = granted
        self.toppedUpBalance = toppedUp
    }
}
