import Foundation

public struct RetentionPolicy: Sendable {
    public let maxAgeDays: Int

    public init(maxAgeDays: Int = 30) {
        self.maxAgeDays = maxAgeDays
    }

    public func prune(
        observations: [WalletObservation],
        relativeTo referenceDate: Date = Date()
    ) -> [WalletObservation] {
        guard let cutoffDate = Calendar.current.date(byAdding: .day, value: -maxAgeDays, to: referenceDate) else {
            return observations
        }

        return observations.filter { observation in
            observation.capturedAt >= cutoffDate
        }
    }
}
