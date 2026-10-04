import Foundation

public struct WalletObservation: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let connectionId: ConnectionID
    public let generationId: ConnectionGenerationID
    public let isAvailable: Bool
    public let balances: [CurrencyBalance]
    public let capturedAt: Date
    public let sourceTimestamp: Date?

    public init(
        id: UUID = UUID(),
        connectionId: ConnectionID,
        generationId: ConnectionGenerationID,
        isAvailable: Bool,
        balances: [CurrencyBalance],
        capturedAt: Date = Date(),
        sourceTimestamp: Date? = nil
    ) {
        self.id = id
        self.connectionId = connectionId
        self.generationId = generationId
        self.isAvailable = isAvailable
        self.balances = balances
        self.capturedAt = capturedAt
        self.sourceTimestamp = sourceTimestamp
    }

    public var primaryBalance: CurrencyBalance? {
        balances.first
    }

    public func balance(for currency: String) -> CurrencyBalance? {
        balances.first { $0.currency.caseInsensitiveCompare(currency) == .orderedSame }
    }

    public var relativeAge: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: capturedAt, relativeTo: Date())
    }
}
