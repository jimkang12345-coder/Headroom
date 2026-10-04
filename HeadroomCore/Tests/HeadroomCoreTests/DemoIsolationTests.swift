import XCTest
@testable import HeadroomCore

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    init(_ initial: Int = 0) {
        self.value = initial
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class DemoIsolationTests: XCTestCase {

    func testDemoModeZeroTransportCallsAndIsolation() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let transportCounter = ThreadSafeCounter(0)
        let mockTransport = MockNetworkTransport { _ in
            transportCounter.increment()
            let response = HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }

        let client = DeepSeekClient(transport: mockTransport)
        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: client
            )
        }

        // Live state initially empty
        let initialConns = await coordinator.connections
        XCTAssertTrue(initialConns.isEmpty)

        // 1. Enter Demo Mode
        await coordinator.toggleDemoMode()
        let isDemo = await coordinator.isDemoMode
        XCTAssertTrue(isDemo)

        // Demo active connections provide synthetic fixtures
        let demoConns = await coordinator.activeConnections
        XCTAssertFalse(demoConns.isEmpty)
        let demoDeepSeek = demoConns.first(where: { $0.providerId == .deepseek })
        XCTAssertNotNil(demoDeepSeek)
        XCTAssertEqual(demoDeepSeek?.userLabel, "Demo Account (Synthetic)")

        let demoObs = await coordinator.activeObservations
        XCTAssertFalse(demoObs.isEmpty)
        let usdBalance = demoObs.first?.balance(for: "USD")
        XCTAssertEqual(usdBalance?.totalBalance, Decimal(string: "12.5000"))

        // 2. Refresh in demo mode causes ZERO transport calls!
        await coordinator.refreshAll()
        await coordinator.refresh(connectionId: demoDeepSeek!.id)
        XCTAssertEqual(transportCounter.count, 0, "Demo mode must NEVER execute network requests!")

        // 3. Exit Demo Mode
        await coordinator.toggleDemoMode()
        let isDemoAfter = await coordinator.isDemoMode
        XCTAssertFalse(isDemoAfter)

        // Verification: Live state is completely unchanged and empty
        let restoredLiveConns = await coordinator.activeConnections
        XCTAssertTrue(restoredLiveConns.isEmpty, "Exiting demo mode must restore unchanged live state")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testErrorPathsNeverInjectSampleBalances() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let mockTransport = MockNetworkTransport { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.deepseek.com/user/balance")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("Service Unavailable".utf8), response)
        }

        let client = DeepSeekClient(transport: mockTransport)
        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: client
            )
        }

        _ = try await coordinator.addConnection(provider: .deepseek, userLabel: "Test", apiKey: "sk-real")

        // Initial verification failed due to 503
        let savedConn = await coordinator.connections.first!
        XCTAssertNil(savedConn.lastObservation, "Error path must NEVER inject synthetic or sample balances into live connection")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMutationProhibitedInDemoMode() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let mockTransport = MockNetworkTransport { _ in
            let response = HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"is_available\": true, \"balance_infos\": []}".utf8), response)
        }
        let client = DeepSeekClient(transport: mockTransport)
        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: client
            )
        }

        // Enter demo mode
        await coordinator.setDemoMode(true)

        // 1. Add connection must throw demoModeActive
        do {
            _ = try await coordinator.addConnection(provider: .deepseek, userLabel: "DemoAdd", apiKey: "sk-demo")
            XCTFail("Expected demoModeActive error")
        } catch CoordinatorError.demoModeActive {
            // Expected
        }

        // 2. Import must throw demoModeActive
        do {
            try await coordinator.importSnapshot(Data("{}".utf8))
            XCTFail("Expected demoModeActive error on import")
        } catch CoordinatorError.demoModeActive {
            // Expected
        }

        // Check live storage remains completely empty
        let loaded = storage.load()
        XCTAssertTrue(loaded.connections.isEmpty, "Live storage must never be mutated while in demo mode")

        try? FileManager.default.removeItem(at: tempDir)
    }

    final class BarrierTransport: NetworkTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var hasReachedBarrier = false
        private var reachedContinuation: CheckedContinuation<Void, Never>?

        func waitUntilReached() async {
            await withCheckedContinuation { cont in
                lock.lock()
                if hasReachedBarrier {
                    lock.unlock()
                    cont.resume()
                } else {
                    reachedContinuation = cont
                    lock.unlock()
                }
            }
        }

        func release() {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume()
        }

        func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let key = request.value(forHTTPHeaderField: "Authorization") ?? ""
            var amount = "10.0000"
            if key.contains("gated") {
                amount = "999.0000"
                await withCheckedContinuation { cont in
                    lock.lock()
                    continuation = cont
                    hasReachedBarrier = true
                    let reached = reachedContinuation
                    reachedContinuation = nil
                    lock.unlock()
                    reached?.resume()
                }
            }
            let json = """
            {
                "is_available": true,
                "balance_infos": [
                    {"currency": "USD", "total_balance": "\(amount)", "granted_balance": "0.0", "topped_up_balance": "\(amount)"}
                ]
            }
            """
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    func testInflightLiveRefreshCancelledOnDemoModeEntry() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let barrierTransport = BarrierTransport()
        let client = DeepSeekClient(transport: barrierTransport)
        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: client
            )
        }

        // Add live connection initially (initial verification is not gated)
        let conn = try await coordinator.addConnection(provider: .deepseek, userLabel: "Live", apiKey: "sk-initial")

        // Trigger refresh with a gated key
        try secretStore.saveSecret("gated-secret", for: conn.credentialId)
        let refreshTask = Task { @MainActor in
            await coordinator.refresh(connectionId: conn.id)
        }

        // Wait until mock transport reaches the continuation barrier
        await barrierTransport.waitUntilReached()

        // Switch to demo mode while request is strictly in-flight
        await coordinator.setDemoMode(true)
        let isDemoInflight = await coordinator.isDemoMode
        XCTAssertTrue(isDemoInflight)

        // Release the barrier
        barrierTransport.release()
        await refreshTask.value

        // Verify active observations in demo mode are the synthetic fixtures, not 999.0000
        let demoObs = await coordinator.activeObservations
        let usdBalance = demoObs.first?.balance(for: "USD")?.totalBalance
        XCTAssertEqual(usdBalance, Decimal(string: "12.5000"), "Demo mode observations must remain synthetic fixtures")

        // Exit demo mode
        await coordinator.setDemoMode(false)
        let liveConn = await coordinator.connections.first(where: { $0.id == conn.id })
        XCTAssertNotNil(liveConn)
        // Late response must not have corrupted live observation
        XCTAssertNotEqual(liveConn?.lastObservation?.primaryBalance?.totalBalance, Decimal(999))

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testExitDemoModeRestoresRealStoreUntouched() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let mockTransport = MockNetworkTransport { _ in
            let json = """
            {
                "is_available": true,
                "balance_infos": [
                    {"currency": "USD", "total_balance": "42.0000", "granted_balance": "0.0", "topped_up_balance": "42.0"}
                ]
            }
            """
            return (Data(json.utf8), HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let client = DeepSeekClient(transport: mockTransport)
        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: client
            )
        }

        // Add real connection
        let liveConn = try await coordinator.addConnection(provider: .deepseek, userLabel: "Real Account", apiKey: "sk-real")
        let liveBalance = await coordinator.connections.first?.lastObservation?.balance(for: "USD")?.totalBalance
        XCTAssertEqual(liveBalance, Decimal(42))

        // Enter demo mode
        await coordinator.setDemoMode(true)
        let isDemoActive = await coordinator.isDemoMode
        XCTAssertTrue(isDemoActive)
        let demoBalance = await coordinator.activeObservations.first?.balance(for: "USD")?.totalBalance
        XCTAssertEqual(demoBalance, Decimal(string: "12.5000"))

        // Exit demo mode
        await coordinator.setDemoMode(false)
        let isDemoInactive = await coordinator.isDemoMode
        XCTAssertFalse(isDemoInactive)

        // Live connection and observation must be perfectly restored
        let restoredConns = await coordinator.activeConnections
        XCTAssertEqual(restoredConns.count, 1)
        XCTAssertEqual(restoredConns.first?.id, liveConn.id)
        XCTAssertEqual(restoredConns.first?.userLabel, "Real Account")
        XCTAssertEqual(restoredConns.first?.lastObservation?.balance(for: "USD")?.totalBalance, Decimal(42))

        try? FileManager.default.removeItem(at: tempDir)
    }
}
