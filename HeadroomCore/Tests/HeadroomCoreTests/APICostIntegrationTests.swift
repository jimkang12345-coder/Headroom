import XCTest
@testable import HeadroomCore

/// Organization cost reports must stay separate from wallet balances and local secrets.
final class APICostIntegrationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!

    @MainActor
    func testVerificationRoutesBothProvidersWithoutInventingWalletBalances() async throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }

        for provider in [ProviderID.openai, .anthropic] {
            let connection = try await harness.coordinator.addConnection(
                provider: provider, userLabel: "Synthetic organization", apiKey: key(for: provider),
                monthlyBudget: Decimal(100)
            )
            let cost = try XCTUnwrap(connection.lastAPICostObservation)
            XCTAssertEqual(connection.state, .ready)
            XCTAssertEqual(cost.providerId, provider)
            XCTAssertEqual(cost.connectionId, connection.id)
            XCTAssertEqual(cost.generationId, connection.generationId)
            XCTAssertEqual(cost.amount, Decimal(string: "12.34"))
            XCTAssertEqual(cost.currency, "USD")
            XCTAssertEqual(cost.capturedAt, now)
            XCTAssertEqual(cost.reportedThrough, monthStart.addingTimeInterval(86_400))
            XCTAssertEqual(connection.monthlyBudget, Decimal(100))
            XCTAssertNil(connection.lastObservation)
            XCTAssertNil(harness.coordinator.observation(for: connection.id))
            XCTAssertEqual(try harness.secrets.readSecret(for: connection.credentialId), key(for: provider))
        }

        let openAIRequests = await harness.openAI.requests
        let anthropicRequests = await harness.anthropic.requests
        XCTAssertEqual(openAIRequests.count, 1)
        XCTAssertEqual(anthropicRequests.count, 1)
        XCTAssertEqual(openAIRequests.first?.url?.host, "api.openai.com")
        XCTAssertEqual(openAIRequests.first?.url?.path, "/v1/organization/costs")
        XCTAssertEqual(openAIRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(key(for: .openai))")
        XCTAssertNil(openAIRequests.first?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(anthropicRequests.first?.url?.host, "api.anthropic.com")
        XCTAssertEqual(anthropicRequests.first?.url?.path, "/v1/organizations/cost_report")
        XCTAssertEqual(anthropicRequests.first?.value(forHTTPHeaderField: "x-api-key"), key(for: .anthropic))
        XCTAssertNil(anthropicRequests.first?.value(forHTTPHeaderField: "Authorization"))
        let walletRequests = await harness.wallet.requests
        XCTAssertTrue(walletRequests.isEmpty)
        XCTAssertTrue(harness.coordinator.observations.isEmpty)

        // The provider distinction and its local target survive an ordinary local restart.
        let persisted = harness.coordinator.storageManager.load()
        XCTAssertEqual(persisted.connections.count, 2)
        XCTAssertTrue(persisted.observations.isEmpty)
        XCTAssertTrue(persisted.connections.allSatisfy {
            $0.lastAPICostObservation?.providerId == $0.providerId && $0.monthlyBudget == Decimal(100)
        })
    }

    @MainActor
    func testAuthFailurePreservesLastReportedCostAndPausesFurtherRefresh() async throws {
        try await assertFailedRefreshPreservesCost(
            response: .init(status: 403), expectedState: .authFailed(statusCode: 403),
            furtherRefreshIsPaused: true
        )
    }

    @MainActor
    func testRateLimitPreservesLastReportedCostAndHonorsRetryDeadline() async throws {
        try await assertFailedRefreshPreservesCost(
            response: .init(status: 429, headers: ["Retry-After": "120"]),
            expectedState: .rateLimited(retryAfter: now.addingTimeInterval(120)),
            furtherRefreshIsPaused: true
        )
    }

    @MainActor
    func testIncompleteReportPreservesLastCostInsteadOfSavingPartialOrZeroTotal() async throws {
        try await assertFailedRefreshPreservesCost(
            response: .init(body: #"{"object":"page","data":[],"has_more":true,"next_page":"synthetic-next"}"#),
            expectedState: .malformedResponse, furtherRefreshIsPaused: false
        )
    }

    @MainActor
    func testCredentialReplacementClearsPreviousCostAndKeepsExplicitBudget() async throws {
        for provider in [ProviderID.openai, .anthropic] {
            let harness = try makeHarness(secondResponse: .init(status: 403))
            defer { harness.cleanUp() }
            let original = try await harness.coordinator.addConnection(
                provider: provider, userLabel: "Synthetic before", apiKey: key(for: provider),
                monthlyBudget: Decimal(75)
            )
            XCTAssertNotNil(original.lastAPICostObservation)
            let replacement = key(for: provider) + "_REPLACEMENT"
            try await harness.coordinator.updateConnection(
                id: original.id, userLabel: "Synthetic after", newApiKey: replacement,
                monthlyBudget: Decimal(75)
            )
            let updated = try XCTUnwrap(harness.coordinator.connections.first)
            XCTAssertEqual(updated.id, original.id)
            XCTAssertNotEqual(updated.credentialId, original.credentialId)
            XCTAssertNotEqual(updated.generationId, original.generationId)
            XCTAssertEqual(updated.state, .authFailed(statusCode: 403))
            XCTAssertNil(updated.lastAPICostObservation, "A different credential cannot inherit the previous organization's cost")
            XCTAssertNil(updated.lastObservation)
            XCTAssertNil(updated.lastSuccessfulRefresh)
            XCTAssertEqual(updated.monthlyBudget, Decimal(75))
            XCTAssertEqual(updated.userLabel, "Synthetic after")
            XCTAssertNil(try harness.secrets.readSecret(for: original.credentialId))
            XCTAssertEqual(try harness.secrets.readSecret(for: updated.credentialId), replacement)
            XCTAssertTrue(harness.coordinator.pendingIntents.isEmpty)
            XCTAssertTrue(harness.coordinator.observations.isEmpty)
        }
    }

    @MainActor
    func testPrivateSnapshotExcludesKeysAndRestoresCostWithFreshUnverifiedIdentities() async throws {
        let source = try makeHarness()
        let destination = try makeHarness()
        defer { source.cleanUp(); destination.cleanUp() }
        var originals: [ProviderID: Connection] = [:]
        for provider in [ProviderID.openai, .anthropic] {
            originals[provider] = try await source.coordinator.addConnection(
                provider: provider, userLabel: "Synthetic private label", apiKey: key(for: provider),
                monthlyBudget: Decimal(string: "100.25")
            )
        }
        let snapshot = try source.coordinator.exportSnapshot()
        let text = try XCTUnwrap(String(data: snapshot, encoding: .utf8))
        XCTAssertFalse(text.contains(key(for: .openai)))
        XCTAssertFalse(text.contains(key(for: .anthropic)))
        XCTAssertFalse(text.contains("credentialId"))
        XCTAssertTrue(text.contains("Synthetic private label"), "Credential-free exports still contain private labels and costs")

        try destination.coordinator.importSnapshot(snapshot)
        XCTAssertEqual(destination.coordinator.connections.count, 2)
        XCTAssertTrue(destination.coordinator.observations.isEmpty)
        for restored in destination.coordinator.connections {
            let original = try XCTUnwrap(originals[restored.providerId])
            let oldCost = try XCTUnwrap(original.lastAPICostObservation)
            let restoredCost = try XCTUnwrap(restored.lastAPICostObservation)
            XCTAssertEqual(restored.state, .awaitingVerification(reason: .importedFromBackup))
            XCTAssertNotEqual(restored.id, original.id)
            XCTAssertNotEqual(restored.credentialId, original.credentialId)
            XCTAssertNotEqual(restored.generationId, original.generationId)
            XCTAssertNotEqual(restoredCost.id, oldCost.id)
            XCTAssertEqual(restoredCost.connectionId, restored.id)
            XCTAssertEqual(restoredCost.generationId, restored.generationId)
            XCTAssertEqual(restoredCost.providerId, restored.providerId)
            XCTAssertEqual(restoredCost.amount, oldCost.amount)
            XCTAssertEqual(restoredCost.periodStart, oldCost.periodStart)
            XCTAssertEqual(restoredCost.periodEnd, oldCost.periodEnd)
            XCTAssertEqual(restoredCost.reportedThrough, oldCost.reportedThrough)
            XCTAssertEqual(restored.monthlyBudget, Decimal(string: "100.25"))
            XCTAssertNil(restored.lastObservation)
            XCTAssertFalse(destination.secrets.hasSecret(for: restored.credentialId))
            await destination.coordinator.refresh(connectionId: restored.id, forced: true)
        }
        let openAIRequests = await destination.openAI.requests
        let anthropicRequests = await destination.anthropic.requests
        let walletRequests = await destination.wallet.requests
        XCTAssertTrue(openAIRequests.isEmpty)
        XCTAssertTrue(anthropicRequests.isEmpty)
        XCTAssertTrue(walletRequests.isEmpty, "Import must not authenticate or acquire readings")
    }

    func testLegacyConnectionDecodesWithoutNewOptionalCostOrBudgetFields() throws {
        let original = Connection(providerId: .deepseek, userLabel: "Synthetic legacy", createdAt: now, updatedAt: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "lastAPICostObservation")
        object.removeValue(forKey: "monthlyBudget")
        object.removeValue(forKey: "credentialId")
        let restored = try JSONDecoder().decode(Connection.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.credentialId, original.id)
        XCTAssertEqual(restored.generationId, original.generationId)
        XCTAssertEqual(restored.providerId, .deepseek)
        XCTAssertNil(restored.lastAPICostObservation)
        XCTAssertNil(restored.monthlyBudget)
    }

    @MainActor
    func testImportRejectsCostWithMismatchedProviderOrConnectionWithoutMutation() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        let connection = Connection(providerId: .openai, userLabel: "Synthetic import", createdAt: now, updatedAt: now)
        for mismatch in ["provider", "connection"] {
            let cost = APICostObservation(
                connectionId: mismatch == "connection" ? ConnectionID() : connection.id,
                generationId: connection.generationId,
                providerId: mismatch == "provider" ? .anthropic : .openai,
                amount: Decimal(3), periodStart: monthStart, periodEnd: now, capturedAt: now,
                reportedThrough: monthStart.addingTimeInterval(86_400)
            )
            let dto = ConnectionSnapshotDTO(
                id: connection.id.uuidString, providerId: connection.providerId.rawValue,
                userLabel: connection.userLabel, createdAt: now, updatedAt: now,
                lastAttemptedRefresh: nil, lastSuccessfulRefresh: now, stateSummary: "Ready",
                monthlyBudget: "50", apiCost: cost
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(SnapshotDTO(exportedAt: now, connections: [dto], observations: []))
            XCTAssertThrowsError(try harness.coordinator.importSnapshot(data), mismatch) { error in
                guard case StorageError.invalidSnapshot = error else {
                    return XCTFail("Expected invalid snapshot for \(mismatch), got \(error)")
                }
            }
            XCTAssertTrue(harness.coordinator.connections.isEmpty)
            XCTAssertTrue(harness.coordinator.observations.isEmpty)
            XCTAssertTrue(harness.coordinator.storageManager.load().connections.isEmpty)
        }
    }

    @MainActor
    func testImportRejectsWalletBalancesUnderAPICostProvidersWithoutMutation() throws {
        let harness = try makeHarness()
        defer { harness.cleanUp() }
        for provider in [ProviderID.openai, .anthropic] {
            let connection = Connection(providerId: provider, userLabel: "Synthetic invalid wallet", createdAt: now, updatedAt: now)
            let wallet = ObservationSnapshotDTO(
                id: UUID().uuidString, connectionId: connection.id.uuidString, isAvailable: true,
                balances: [CurrencyBalanceSnapshotDTO(currency: "USD", total: "4.50", granted: "0", toppedUp: "4.50")],
                capturedAt: now
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // No apiCost exists to trigger its separate validation: provider semantics must reject this wallet record.
            let data = try encoder.encode(SnapshotDTO(
                exportedAt: now, connections: [ConnectionSnapshotDTO(from: connection)], observations: [wallet]
            ))
            XCTAssertThrowsError(try harness.coordinator.importSnapshot(data), provider.rawValue) { error in
                guard case StorageError.invalidSnapshot = error else {
                    return XCTFail("Expected invalid snapshot for API provider wallet data, got \(error)")
                }
            }
            XCTAssertTrue(harness.coordinator.connections.isEmpty)
            XCTAssertTrue(harness.coordinator.observations.isEmpty)
            let persisted = harness.coordinator.storageManager.load()
            XCTAssertTrue(persisted.connections.isEmpty)
            XCTAssertTrue(persisted.observations.isEmpty)
        }
    }

    @MainActor
    private func assertFailedRefreshPreservesCost(
        response: CostIntegrationResponse, expectedState: ConnectionState, furtherRefreshIsPaused: Bool
    ) async throws {
        for provider in [ProviderID.openai, .anthropic] {
            let harness = try makeHarness(secondResponse: response)
            defer { harness.cleanUp() }
            let original = try await harness.coordinator.addConnection(
                provider: provider, userLabel: "Synthetic last known", apiKey: key(for: provider),
                monthlyBudget: Decimal(40)
            )
            let originalCost = try XCTUnwrap(original.lastAPICostObservation)
            await harness.coordinator.refresh(connectionId: original.id, forced: true)
            let failed = try XCTUnwrap(harness.coordinator.connections.first)
            XCTAssertEqual(failed.state, expectedState)
            XCTAssertEqual(failed.lastAPICostObservation, originalCost)
            XCTAssertEqual(failed.lastSuccessfulRefresh, original.lastSuccessfulRefresh)
            XCTAssertEqual(failed.monthlyBudget, Decimal(40))
            XCTAssertNil(failed.lastObservation)
            XCTAssertTrue(harness.coordinator.observations.isEmpty)
            let persisted = try XCTUnwrap(harness.coordinator.storageManager.load().connections.first)
            XCTAssertEqual(persisted.lastAPICostObservation, originalCost)
            XCTAssertEqual(persisted.state, expectedState)

            if furtherRefreshIsPaused {
                await harness.coordinator.refresh(connectionId: original.id, forced: true)
            }
            let requests = await (provider == .openai ? harness.openAI : harness.anthropic).requests
            XCTAssertEqual(requests.count, 2, "Auth failures and unexpired rate limits must not be retried by ordinary refresh")
        }
    }

    private var monthStart: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateInterval(of: .month, for: now)!.start
    }

    private func key(for provider: ProviderID) -> String {
        provider == .openai ? "sk-admin-SYNTHETIC_HEADROOM_TEST" : "sk-ant-admin01-SYNTHETIC_HEADROOM_TEST"
    }

    @MainActor
    private func makeHarness(secondResponse: CostIntegrationResponse? = nil) throws -> CostIntegrationHarness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-cost-test-\(UUID().uuidString)")
        let additionalResponses = secondResponse.map { [$0] } ?? []
        let openAI = CostIntegrationTransport(responses: [.init(body: openAIReport)] + additionalResponses)
        let anthropic = CostIntegrationTransport(responses: [.init(body: anthropicReport)] + additionalResponses)
        let wallet = CostIntegrationTransport(responses: [])
        let secrets = InMemorySecretStore()
        let fixedNow = now
        let coordinator = WalletCoordinator(
            secretStore: secrets, storageManager: AppStorageManager(storageDirectory: directory),
            deepSeekClient: DeepSeekClient(transport: wallet, dateProvider: { fixedNow }),
            openAICostClient: OpenAICostClient(transport: openAI, dateProvider: { fixedNow }),
            anthropicCostClient: AnthropicCostClient(transport: anthropic, dateProvider: { fixedNow }),
            clock: { fixedNow }
        )
        return CostIntegrationHarness(directory: directory, coordinator: coordinator, secrets: secrets,
                                      openAI: openAI, anthropic: anthropic, wallet: wallet)
    }

    private var openAIReport: String {
        """
        {"object":"page","data":[{"object":"bucket","start_time":\(Int64(monthStart.timeIntervalSince1970)),"end_time":\(Int64(monthStart.addingTimeInterval(86_400).timeIntervalSince1970)),"results":[{"object":"organization.costs.result","amount":{"value":12.34,"currency":"usd"}}]}],"has_more":false,"next_page":null}
        """
    }

    private var anthropicReport: String {
        let formatter = ISO8601DateFormatter()
        return """
        {"data":[{"starting_at":"\(formatter.string(from: monthStart))","ending_at":"\(formatter.string(from: monthStart.addingTimeInterval(86_400)))","results":[{"amount":"1234","currency":"USD"}]}],"has_more":false,"next_page":null}
        """
    }
}

private struct CostIntegrationResponse: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = "{}"
}

private actor CostIntegrationTransport: NetworkTransport {
    private var responses: [CostIntegrationResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [CostIntegrationResponse]) { self.responses = responses }

    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty, let url = request.url else { throw APICostError.networkError }
        let next = responses.removeFirst()
        return (Data(next.body.utf8), HTTPURLResponse(url: url, statusCode: next.status, httpVersion: nil,
                                                   headerFields: next.headers)!)
    }
}

@MainActor
private struct CostIntegrationHarness {
    let directory: URL
    let coordinator: WalletCoordinator
    let secrets: InMemorySecretStore
    let openAI: CostIntegrationTransport
    let anthropic: CostIntegrationTransport
    let wallet: CostIntegrationTransport

    func cleanUp() {
        coordinator.pauseScheduling()
        try? FileManager.default.removeItem(at: directory)
    }
}
