import XCTest
@testable import HeadroomCore

private final class AcquisitionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    func now() -> Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

private actor AcquisitionScenarioTransport: NetworkTransport {
    enum Scenario: Sendable { case success, forbidden, timeout, gatedSuccess }
    private var scenario: Scenario = .success
    private(set) var requestCount = 0
    private var barrierEntered = false
    private var barrierWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func setScenario(_ next: Scenario) { scenario = next }
    func waitUntilBlocked() async {
        if barrierEntered { return }
        await withCheckedContinuation { barrierWaiters.append($0) }
    }
    func releaseResponse() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        switch scenario {
        case .forbidden:
            return (Data("SYNTHETIC_RAW_FORBIDDEN_RESPONSE".utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        case .timeout:
            // Inject the categorized error returned by SecureURLSessionTransport on a timeout.
            throw DeepSeekError.timeout
        case .gatedSuccess:
            barrierEntered = true
            let waiting = barrierWaiters; barrierWaiters.removeAll()
            for waiter in waiting { waiter.resume() }
            // Deliberately ignore cancellation to exercise coordinator ownership checks.
            await withCheckedContinuation { releaseContinuation = $0 }
        case .success: break
        }
        let json = #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.5000","granted_balance":"2.5000","topped_up_balance":"10.0000"},{"currency":"CNY","total_balance":"80.00","granted_balance":"0.00","topped_up_balance":"80.00"}]}"#
        return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

final class AcquisitionErrorCoverageTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("headroom-b05-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor func test403PreservesDatedReadingAndPausesOrdinaryAcquisitionThroughRestart() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = AcquisitionTestClock(Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        let secrets = InMemorySecretStore()
        let transport = AcquisitionScenarioTransport()
        let client = DeepSeekClient(transport: transport, dateProvider: { clock.now() })
        let storage = AppStorageManager(storageDirectory: dir)
        let coordinator = WalletCoordinator(secretStore: secrets, storageManager: storage, deepSeekClient: client, clock: { clock.now() })
        let original = try await coordinator.addConnection(provider: .deepseek, userLabel: "Synthetic 403", apiKey: "synthetic-403")
        let history = coordinator.observations
        clock.advance(60)
        await transport.setScenario(.forbidden)
        await coordinator.refresh(connectionId: original.id, forced: true)
        let failed = try XCTUnwrap(coordinator.connections.first)
        XCTAssertEqual(failed.state, .authFailed(statusCode: 403))
        XCTAssertEqual(failed.lastSuccessfulRefresh, original.lastSuccessfulRefresh)
        XCTAssertEqual(failed.lastObservation, original.lastObservation)
        XCTAssertEqual(failed.lastAttemptedRefresh, clock.now())
        XCTAssertEqual(coordinator.observations, history)
        XCTAssertFalse(String(decoding: try Data(contentsOf: storage.storeFileURL), as: UTF8.self).contains("SYNTHETIC_RAW_FORBIDDEN_RESPONSE"))
        let restarted = WalletCoordinator(secretStore: secrets, storageManager: AppStorageManager(storageDirectory: dir), deepSeekClient: client, clock: { clock.now() })
        XCTAssertEqual(restarted.connections.first?.state, .authFailed(statusCode: 403))
        XCTAssertEqual(restarted.connections.first?.lastObservation, original.lastObservation)
        await restarted.refreshAll(forced: false)
        await restarted.refreshAll(forced: true)
        let count = await transport.requestCount
        XCTAssertEqual(count, 2)
        coordinator.pauseScheduling(); restarted.pauseScheduling()
    }

    @MainActor func testTransportTimeoutPreservesPriorReadingAndSeparatesAttemptTimeThroughRestart() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = AcquisitionTestClock(Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        let secrets = InMemorySecretStore()
        let transport = AcquisitionScenarioTransport()
        let client = DeepSeekClient(transport: transport, dateProvider: { clock.now() })
        let coordinator = WalletCoordinator(secretStore: secrets, storageManager: AppStorageManager(storageDirectory: dir), deepSeekClient: client, clock: { clock.now() })
        let original = try await coordinator.addConnection(provider: .deepseek, userLabel: "Synthetic timeout", apiKey: "synthetic-timeout")
        let history = coordinator.observations
        clock.advance(120)
        await transport.setScenario(.timeout)
        await coordinator.refresh(connectionId: original.id, forced: true)
        let failed = try XCTUnwrap(coordinator.connections.first)
        XCTAssertEqual(failed.state, .timeout)
        XCTAssertEqual(failed.lastSuccessfulRefresh, original.lastSuccessfulRefresh)
        XCTAssertEqual(failed.lastObservation, original.lastObservation)
        XCTAssertEqual(failed.lastAttemptedRefresh, clock.now())
        XCTAssertEqual(coordinator.observations, history)
        let restarted = WalletCoordinator(secretStore: secrets, storageManager: AppStorageManager(storageDirectory: dir), deepSeekClient: client, clock: { clock.now() })
        XCTAssertEqual(restarted.connections.first?.state, .timeout)
        XCTAssertEqual(restarted.connections.first?.lastObservation, original.lastObservation)
        XCTAssertEqual(restarted.connections.first?.lastSuccessfulRefresh, original.lastSuccessfulRefresh)
        XCTAssertEqual(restarted.connections.first?.lastAttemptedRefresh, clock.now())
        let count = await transport.requestCount
        XCTAssertEqual(count, 2)
        coordinator.pauseScheduling(); restarted.pauseScheduling()
    }

    @MainActor func testLateRefreshResultCannotResurrectDeletedAccountOrHistory() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let transport = AcquisitionScenarioTransport()
        let client = DeepSeekClient(transport: transport)
        let storage = AppStorageManager(storageDirectory: dir)
        let coordinator = WalletCoordinator(secretStore: secrets, storageManager: storage, deepSeekClient: client)
        let original = try await coordinator.addConnection(provider: .deepseek, userLabel: "Synthetic delete", apiKey: "synthetic-delete")
        await transport.setScenario(.gatedSuccess)
        let pending = Task { await coordinator.refresh(connectionId: original.id, forced: true) }
        await transport.waitUntilBlocked()
        try coordinator.removeConnection(id: original.id)
        let deletedBytes = try Data(contentsOf: storage.storeFileURL)
        XCTAssertNil(try secrets.readSecret(for: original.credentialId))
        XCTAssertTrue(coordinator.connections.isEmpty)
        XCTAssertTrue(coordinator.observations.isEmpty)
        await transport.releaseResponse()
        await pending.value
        XCTAssertEqual(try Data(contentsOf: storage.storeFileURL), deletedBytes)
        XCTAssertTrue(coordinator.connections.isEmpty)
        XCTAssertTrue(coordinator.observations.isEmpty)
        XCTAssertTrue(coordinator.pendingIntents.isEmpty)
        let restarted = WalletCoordinator(secretStore: secrets, storageManager: AppStorageManager(storageDirectory: dir), deepSeekClient: client)
        XCTAssertTrue(restarted.connections.isEmpty)
        XCTAssertTrue(restarted.observations.isEmpty)
        XCTAssertTrue(restarted.pendingIntents.isEmpty)
        await restarted.refreshAll(forced: true)
        let count = await transport.requestCount
        XCTAssertEqual(count, 2)
        coordinator.pauseScheduling(); restarted.pauseScheduling()
    }

    @MainActor func testLateInitialVerificationCannotResurrectDeletedAccount() async throws {
        let dir = try directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let secrets = InMemorySecretStore()
        let transport = AcquisitionScenarioTransport()
        await transport.setScenario(.gatedSuccess)
        let storage = AppStorageManager(storageDirectory: dir)
        let coordinator = WalletCoordinator(secretStore: secrets, storageManager: storage, deepSeekClient: DeepSeekClient(transport: transport))
        let adding = Task { try await coordinator.addConnection(provider: .deepseek, userLabel: "Synthetic pending add", apiKey: "synthetic-add") }
        await transport.waitUntilBlocked()
        let pendingConnection = try XCTUnwrap(coordinator.connections.first)
        try coordinator.removeConnection(id: pendingConnection.id)
        let deletedBytes = try Data(contentsOf: storage.storeFileURL)
        await transport.releaseResponse()
        _ = try await adding.value
        XCTAssertEqual(try Data(contentsOf: storage.storeFileURL), deletedBytes)
        XCTAssertTrue(coordinator.connections.isEmpty)
        XCTAssertTrue(coordinator.observations.isEmpty)
        XCTAssertTrue(coordinator.pendingIntents.isEmpty)
        XCTAssertNil(try secrets.readSecret(for: pendingConnection.credentialId))
        let count = await transport.requestCount
        XCTAssertEqual(count, 1)
        coordinator.pauseScheduling()
    }
}
