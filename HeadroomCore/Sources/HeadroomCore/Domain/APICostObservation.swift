import Foundation

/// Provider-reported organization API cost, never a prepaid balance or subscription quota.
public struct APICostObservation: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let connectionId: ConnectionID
    public let generationId: ConnectionGenerationID
    public let providerId: ProviderID
    public let amount: Decimal
    public let currency: String
    public let periodStart: Date
    /// Exclusive query boundary. Billing data can arrive later than this snapshot.
    public let periodEnd: Date
    public let capturedAt: Date
    /// Latest returned daily bucket boundary, capped at the query snapshot.
    /// An empty report has no reported coverage beyond periodStart.
    public let reportedThrough: Date

    public init(
        id: UUID = UUID(),
        connectionId: ConnectionID,
        generationId: ConnectionGenerationID,
        providerId: ProviderID,
        amount: Decimal,
        currency: String = "USD",
        periodStart: Date,
        periodEnd: Date,
        capturedAt: Date,
        reportedThrough: Date? = nil
    ) {
        self.id = id
        self.connectionId = connectionId
        self.generationId = generationId
        self.providerId = providerId
        self.amount = amount
        self.currency = currency
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.capturedAt = capturedAt
        self.reportedThrough = reportedThrough ?? periodStart
    }
}

/// A local comparison target. Headroom does not enforce provider spending limits.
public struct LocalAPIMonthlyBudget: Hashable, Codable, Sendable {
    public let amount: Decimal
    public let currency: String

    public init(amount: Decimal, currency: String = "USD") throws {
        guard !amount.isNaN, amount > 0,
              currency == "USD" else {
            throw APICostError.malformedResponse
        }
        self.amount = amount
        self.currency = currency
    }

    public static func parse(_ raw: String) throws -> LocalAPIMonthlyBudget {
        let amount = try CurrencyBalance.parseDecimalStrict(raw, fieldName: "monthly_budget")
        return try LocalAPIMonthlyBudget(amount: amount)
    }
}
