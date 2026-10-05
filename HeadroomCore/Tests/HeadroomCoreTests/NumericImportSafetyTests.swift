import XCTest
@testable import HeadroomCore

final class NumericImportSafetyTests: XCTestCase {
    @MainActor
    func testImportRejectsOversizedBalanceFieldsWithoutChangingExistingState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-numeric-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = try makeCoordinator(directory: directory)
        let original = try Data(contentsOf: coordinator.storageManager.storeFileURL)
        let originalIDs = coordinator.connections.map(\.id)
        let oversized = String(repeating: "0", count: 100_000) + "1"
        let fields = ["total_balance", "granted_balance", "topped_up_balance"]

        for field in 0..<3 {
            var amounts = ["1.00", "0.00", "1.00"]
            amounts[field] = oversized
            let data = try snapshot(amounts: amounts)
            XCTAssertLessThan(data.count, AppStorageManager.maxImportSizeBytes)
            XCTAssertThrowsError(try coordinator.importSnapshot(data)) { error in
                XCTAssertEqual(error as? CurrencyBalance.ParseError, .invalidDecimalString(field: fields[field]))
            }
            XCTAssertEqual(coordinator.connections.map(\.id), originalIDs)
            XCTAssertTrue(coordinator.observations.isEmpty)
            XCTAssertEqual(try Data(contentsOf: coordinator.storageManager.storeFileURL), original)
        }
    }

    @MainActor
    func testImportRejectsOversizedMonthlyTargetWithoutChangingExistingState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-numeric-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = try makeCoordinator(directory: directory)
        let original = try Data(contentsOf: coordinator.storageManager.storeFileURL)
        let originalIDs = coordinator.connections.map(\.id)
        for raw in [String(repeating: "0", count: 100_000) + "1", "1." + String(repeating: "0", count: 100_000)] {
            let data = try snapshot(monthlyBudget: raw)
            XCTAssertLessThan(data.count, AppStorageManager.maxImportSizeBytes)
            XCTAssertThrowsError(try coordinator.importSnapshot(data)) { error in
                XCTAssertEqual(error as? CurrencyBalance.ParseError, .invalidDecimalString(field: "monthly_budget"))
            }
            XCTAssertEqual(coordinator.connections.map(\.id), originalIDs)
            XCTAssertTrue(coordinator.observations.isEmpty)
            XCTAssertEqual(try Data(contentsOf: coordinator.storageManager.storeFileURL), original)
        }
    }

    @MainActor
    func testImportRetainsLegitimateExactAmountsRawFormattingAndMonthlyTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-numeric-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = try makeCoordinator(directory: directory)
        let amounts = [" \t-0002.5000\n", "-0.0000", "+00012.3400"]
        try coordinator.importSnapshot(snapshot(amounts: amounts, monthlyBudget: " \t+000100.2500\n"))
        let wallet = try XCTUnwrap(coordinator.observations.last)
        let balance = try XCTUnwrap(wallet.balances.first)
        XCTAssertEqual(balance.totalBalance, Decimal(string: "-2.5"))
        XCTAssertEqual(balance.grantedBalance, .zero)
        XCTAssertEqual(balance.toppedUpBalance, Decimal(string: "12.34"))
        XCTAssertEqual([balance.rawTotal, balance.rawGranted, balance.rawToppedUp], amounts)
        let costConnection = try XCTUnwrap(coordinator.connections.first { $0.providerId == .openai })
        XCTAssertEqual(costConnection.monthlyBudget, Decimal(string: "100.25"))
        XCTAssertEqual(costConnection.state, .awaitingVerification(reason: .importedFromBackup))
        XCTAssertFalse(coordinator.secretStore.hasSecret(for: costConnection.credentialId))
    }

    @MainActor
    private func makeCoordinator(directory: URL) throws -> WalletCoordinator {
        let storage = AppStorageManager(storageDirectory: directory)
        try storage.save(StoredData(connections: [Connection(providerId: .deepseek, userLabel: "Synthetic existing")]))
        let transport = MockNetworkTransport { _ in
            XCTFail("Snapshot import must not request provider data")
            throw URLError(.notConnectedToInternet)
        }
        let coordinator = WalletCoordinator(
            secretStore: InMemorySecretStore(), storageManager: storage,
            deepSeekClient: DeepSeekClient(transport: transport),
            openAICostClient: OpenAICostClient(transport: transport),
            anthropicCostClient: AnthropicCostClient(transport: transport)
        )
        coordinator.pauseScheduling()
        return coordinator
    }

    private func snapshot(amounts: [String]? = nil, monthlyBudget: String? = nil) throws -> Data {
        let date = Date().addingTimeInterval(-60)
        var connections: [ConnectionSnapshotDTO] = []
        var observations: [ObservationSnapshotDTO] = []
        if let amounts {
            let id = UUID().uuidString
            connections.append(connection(id: id, provider: .deepseek, date: date))
            observations.append(ObservationSnapshotDTO(
                id: UUID().uuidString, connectionId: id, isAvailable: true,
                balances: [CurrencyBalanceSnapshotDTO(currency: "USD", total: amounts[0], granted: amounts[1], toppedUp: amounts[2])],
                capturedAt: date
            ))
        }
        if let monthlyBudget {
            connections.append(connection(id: UUID().uuidString, provider: .openai, date: date, monthlyBudget: monthlyBudget))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(SnapshotDTO(exportedAt: date, connections: connections, observations: observations))
    }

    private func connection(id: String, provider: ProviderID, date: Date, monthlyBudget: String? = nil) -> ConnectionSnapshotDTO {
        ConnectionSnapshotDTO(
            id: id, providerId: provider.rawValue, userLabel: "Synthetic import", createdAt: date, updatedAt: date,
            lastAttemptedRefresh: nil, lastSuccessfulRefresh: nil, stateSummary: "Synthetic", monthlyBudget: monthlyBudget
        )
    }
}
