import Foundation

public struct Connection: Hashable, Codable, Sendable, Identifiable {
    public let id: ConnectionID
    public var credentialId: ConnectionID
    public var generationId: ConnectionGenerationID
    public let providerId: ProviderID
    public var userLabel: String
    public let createdAt: Date
    public var updatedAt: Date
    public var lastAttemptedRefresh: Date?
    public var lastSuccessfulRefresh: Date?
    public var lastObservation: WalletObservation?
    public var lastAPICostObservation: APICostObservation?
    public var monthlyBudget: Decimal?
    public var state: ConnectionState

    public init(
        id: ConnectionID = ConnectionID(),
        credentialId: ConnectionID? = nil,
        generationId: ConnectionGenerationID = ConnectionGenerationID(),
        providerId: ProviderID,
        userLabel: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastAttemptedRefresh: Date? = nil,
        lastSuccessfulRefresh: Date? = nil,
        lastObservation: WalletObservation? = nil,
        lastAPICostObservation: APICostObservation? = nil,
        monthlyBudget: Decimal? = nil,
        state: ConnectionState = .notConfigured
    ) {
        self.id = id
        self.credentialId = credentialId ?? id
        self.generationId = generationId
        self.providerId = providerId
        self.userLabel = userLabel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAttemptedRefresh = lastAttemptedRefresh
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
        self.lastObservation = lastObservation
        self.lastAPICostObservation = lastAPICostObservation
        self.monthlyBudget = monthlyBudget
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case id
        case credentialId
        case generationId
        case providerId
        case userLabel
        case createdAt
        case updatedAt
        case lastAttemptedRefresh
        case lastSuccessfulRefresh
        case lastObservation
        case lastAPICostObservation
        case monthlyBudget
        case state
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(ConnectionID.self, forKey: .id)
        self.credentialId = try container.decodeIfPresent(ConnectionID.self, forKey: .credentialId) ?? self.id
        self.generationId = try container.decode(ConnectionGenerationID.self, forKey: .generationId)
        self.providerId = try container.decode(ProviderID.self, forKey: .providerId)
        self.userLabel = try container.decode(String.self, forKey: .userLabel)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.lastAttemptedRefresh = try container.decodeIfPresent(Date.self, forKey: .lastAttemptedRefresh)
        self.lastSuccessfulRefresh = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulRefresh)
        self.lastObservation = try container.decodeIfPresent(WalletObservation.self, forKey: .lastObservation)
        self.lastAPICostObservation = try container.decodeIfPresent(APICostObservation.self, forKey: .lastAPICostObservation)
        self.monthlyBudget = try container.decodeIfPresent(Decimal.self, forKey: .monthlyBudget)
        self.state = try container.decode(ConnectionState.self, forKey: .state)
    }

    public var effectiveLabel: String {
        userLabel.isEmpty ? providerId.displayName : userLabel
    }
}
