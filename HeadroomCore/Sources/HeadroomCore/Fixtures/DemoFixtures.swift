import Foundation

public enum DemoFixtures {
    public static let deepSeekConnectionID = ConnectionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    public static let codexConnectionID = ConnectionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    public static let claudeConnectionID = ConnectionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
    public static let antigravityConnectionID = ConnectionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)
    public static let offlineConnectionID = ConnectionID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!)

    public static func makeDemoConnections() -> [Connection] {
        let fixedDate = Date(timeIntervalSince1970: 1774350000) // Deterministic capture date
        let earlierDate = Date(timeIntervalSince1970: 1774339200) // 3 hours earlier

        let deepSeekObservation = WalletObservation(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            connectionId: deepSeekConnectionID,
            generationId: ConnectionGenerationID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222221")!),
            isAvailable: true,
            balances: [
                CurrencyBalance(
                    currency: "USD",
                    totalBalance: Decimal(string: "12.5000")!,
                    grantedBalance: Decimal(string: "2.5000")!,
                    toppedUpBalance: Decimal(string: "10.0000")!,
                    rawTotal: "12.5000",
                    rawGranted: "2.5000",
                    rawToppedUp: "10.0000"
                ),
                CurrencyBalance(
                    currency: "CNY",
                    totalBalance: Decimal(string: "45.0000")!,
                    grantedBalance: Decimal(string: "10.0000")!,
                    toppedUpBalance: Decimal(string: "35.0000")!,
                    rawTotal: "45.0000",
                    rawGranted: "10.0000",
                    rawToppedUp: "35.0000"
                )
            ],
            capturedAt: fixedDate,
            sourceTimestamp: nil
        )

        let deepSeekConn = Connection(
            id: deepSeekConnectionID,
            generationId: ConnectionGenerationID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222221")!),
            providerId: .deepseek,
            userLabel: "Demo Account (Synthetic)",
            createdAt: fixedDate,
            updatedAt: fixedDate,
            lastAttemptedRefresh: fixedDate,
            lastSuccessfulRefresh: fixedDate,
            lastObservation: deepSeekObservation,
            state: .ready
        )

        let offlineObservation = WalletObservation(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            connectionId: offlineConnectionID,
            generationId: ConnectionGenerationID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444441")!),
            isAvailable: true,
            balances: [
                CurrencyBalance(
                    currency: "USD",
                    totalBalance: Decimal(string: "5.0000")!,
                    grantedBalance: Decimal(string: "0.0000")!,
                    toppedUpBalance: Decimal(string: "5.0000")!,
                    rawTotal: "5.0000",
                    rawGranted: "0.0000",
                    rawToppedUp: "5.0000"
                )
            ],
            capturedAt: earlierDate,
            sourceTimestamp: nil
        )

        let offlineConn = Connection(
            id: offlineConnectionID,
            generationId: ConnectionGenerationID(rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444441")!),
            providerId: .deepseek,
            userLabel: "Stale Account (Offline)",
            createdAt: earlierDate,
            updatedAt: fixedDate,
            lastAttemptedRefresh: fixedDate,
            lastSuccessfulRefresh: earlierDate,
            lastObservation: offlineObservation,
            state: .offline(lastAttempt: fixedDate)
        )

        return [deepSeekConn, offlineConn]
    }

    public static func makeDemoObservations() -> [WalletObservation] {
        makeDemoConnections().compactMap(\.lastObservation)
    }
}
