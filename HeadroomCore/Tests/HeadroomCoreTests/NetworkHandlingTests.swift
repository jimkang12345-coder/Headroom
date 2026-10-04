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

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ initial: Bool = false) {
        self.value = initial
    }

    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class NetworkHandlingTests: XCTestCase {

    func testCoalescingConcurrentRefreshTriggers() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let requestCounter = ThreadSafeCounter(0)
        let mockTransport = MockNetworkTransport { _ in
            requestCounter.increment()
            // Sleep briefly to simulate network latency
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms

            let validJSON = """
            {
                "is_available": true,
                "balance_infos": [
                    {
                        "currency": "USD",
                        "total_balance": "25.0000",
                        "granted_balance": "5.0000",
                        "topped_up_balance": "20.0000"
                    }
                ]
            }
            """
            let response = HTTPURLResponse(
                url: URL(string: "https://api.deepseek.com/user/balance")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(validJSON.utf8), response)
        }

        let client = DeepSeekClient(transport: mockTransport)
        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: client
            )
        }

        let conn = try await coordinator.addConnection(provider: .deepseek, userLabel: "Test", apiKey: "sk-test")
        XCTAssertEqual(requestCounter.count, 1, "Initial add connection triggers 1 verification request")

        // Trigger concurrent refreshes simultaneously
        async let r1: () = coordinator.refresh(connectionId: conn.id)
        async let r2: () = coordinator.refresh(connectionId: conn.id)
        async let r3: () = coordinator.refresh(connectionId: conn.id)
        async let r4: () = coordinator.refresh(connectionId: conn.id)
        async let r5: () = coordinator.refresh(connectionId: conn.id)
        _ = await (r1, r2, r3, r4, r5)

        // Verification: Exactly 1 additional network request occurred because all concurrent triggers coalesced!
        XCTAssertEqual(requestCounter.count, 2, "Concurrent refreshes must coalesce into a single in-flight network call")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testFailedRefreshRetainsPriorSuccessfulReading() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let failFlag = ThreadSafeFlag(false)
        let mockTransport = MockNetworkTransport { _ in
            if failFlag.isSet {
                let errorResponse = HTTPURLResponse(
                    url: URL(string: "https://api.deepseek.com/user/balance")!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data("Internal Server Error".utf8), errorResponse)
            } else {
                let validJSON = """
                {
                    "is_available": true,
                    "balance_infos": [
                        {
                            "currency": "USD",
                            "total_balance": "100.0000",
                            "granted_balance": "0.0000",
                            "topped_up_balance": "100.0000"
                        }
                    ]
                }
                """
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.deepseek.com/user/balance")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(validJSON.utf8), response)
            }
        }

        let client = DeepSeekClient(transport: mockTransport)
        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: client
            )
        }

        // 1. Initial successful connection
        let conn = try await coordinator.addConnection(provider: .deepseek, userLabel: "Test", apiKey: "sk-test")
        let firstObs = await coordinator.connections.first!.lastObservation
        XCTAssertNotNil(firstObs)
        XCTAssertEqual(firstObs?.balance(for: "USD")?.totalBalance, Decimal(100))

        // 2. Now simulate network 500 error on subsequent refresh
        failFlag.set(true)
        await coordinator.refresh(connectionId: conn.id, forced: true)

        let updatedConn = await coordinator.connections.first!
        // State is server error (500)
        if case .serverError(let code) = updatedConn.state, code == 500 {
            // expected
        } else {
            XCTFail("Expected serverError(statusCode: 500), got \(updatedConn.state)")
        }

        // CRITICAL INVARIANT: Prior successful reading is retained!
        XCTAssertNotNil(updatedConn.lastObservation, "Failed refresh must retain dated prior successful reading")
        XCTAssertEqual(updatedConn.lastObservation?.balance(for: "USD")?.totalBalance, Decimal(100))
        XCTAssertEqual(updatedConn.lastObservation?.capturedAt, firstObs?.capturedAt)

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRateLimitWithRetryAfterRespected() async throws {
        let mockTransport = MockNetworkTransport { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.deepseek.com/user/balance")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "60"] // 60 seconds
            )!
            return (Data("Rate limited".utf8), response)
        }

        let client = DeepSeekClient(transport: mockTransport)
        do {
            _ = try await client.fetchBalance(apiKey: "sk-test", connectionId: ConnectionID(), generationId: ConnectionGenerationID())
            XCTFail("Expected rate limited error")
        } catch let DeepSeekError.rateLimited(retryAfter) {
            // Retry date should be ~60s in future
            let interval = retryAfter.timeIntervalSince(Date())
            XCTAssertGreaterThanOrEqual(interval, 55)
            XCTAssertLessThanOrEqual(interval, 65)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAuthFailureMarksConnectionAndDoesNotRetryInLoop() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let requestCounter = ThreadSafeCounter(0)
        let mockTransport = MockNetworkTransport { _ in
            requestCounter.increment()
            let response = HTTPURLResponse(
                url: URL(string: "https://api.deepseek.com/user/balance")!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("{\"error\": {\"message\": \"Authentication Fails\"}}".utf8), response)
        }

        let client = DeepSeekClient(transport: mockTransport)
        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: client
            )
        }

        _ = try await coordinator.addConnection(provider: .deepseek, userLabel: "BadKey", apiKey: "sk-invalid")
        XCTAssertEqual(requestCounter.count, 1)

        let updatedConn = await coordinator.connections.first!
        if case .authFailed(let code) = updatedConn.state {
            XCTAssertEqual(code, 401)
        } else {
            XCTFail("Expected authFailed state, got \(updatedConn.state)")
        }

        // Test that auto-refresh skips authFailure connections
        await coordinator.refreshAll(forced: false)
        XCTAssertEqual(requestCounter.count, 1, "Auto-refresh must skip connections with authFailure")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testManualRefreshHonorsActiveRetryAfterDeadline() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let requestCounter = ThreadSafeCounter(0)
        let mockTransport = MockNetworkTransport { _ in
            requestCounter.increment()
            let response = HTTPURLResponse(
                url: URL(string: "https://api.deepseek.com/user/balance")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "120"]
            )!
            return (Data("Rate limited".utf8), response)
        }

        let client = DeepSeekClient(transport: mockTransport)
        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: client
            )
        }

        let conn = try await coordinator.addConnection(provider: .deepseek, userLabel: "Test", apiKey: "sk-rate")
        XCTAssertEqual(requestCounter.count, 1)

        // Attempt normal refresh before deadline has passed
        await coordinator.refresh(connectionId: conn.id, forced: false)
        XCTAssertEqual(requestCounter.count, 1, "Unforced refresh must respect active Retry-After deadline")

        // Forced refresh must ALSO respect active Retry-After deadline (no manual bypass of provider backoff)
        await coordinator.refresh(connectionId: conn.id, forced: true)
        XCTAssertEqual(requestCounter.count, 1, "Even forced refresh must respect active Retry-After deadline")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLateResponseFromReplacedKeyIsDiscarded() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let mockTransport = MockNetworkTransport { req in
            let key = req.value(forHTTPHeaderField: "Authorization") ?? ""
            if key.contains("key-1") {
                // Delay first key response
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                let json = """
                {
                    "is_available": true,
                    "balance_infos": [
                        {"currency": "USD", "total_balance": "10.0000", "granted_balance": "0.0000", "topped_up_balance": "10.0000"}
                    ]
                }
                """
                return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            } else {
                let json = """
                {
                    "is_available": true,
                    "balance_infos": [
                        {"currency": "USD", "total_balance": "50.0000", "granted_balance": "0.0000", "topped_up_balance": "50.0000"}
                    ]
                }
                """
                return (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }

        let client = DeepSeekClient(transport: mockTransport)
        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: client
            )
        }

        // Add with key-1
        let conn = try await coordinator.addConnection(provider: .deepseek, userLabel: "Test", apiKey: "key-1")

        // In-flight refresh with key-1
        let refreshTask = Task { @MainActor in
            await coordinator.refresh(connectionId: conn.id)
        }

        // Immediately replace key with key-2 before key-1 finishes
        try await coordinator.updateConnection(id: conn.id, userLabel: "Test", newApiKey: "key-2")

        _ = await refreshTask.value

        let currentConn = await coordinator.connections.first!
        // Should have balance from key-2 ($50.00), NOT key-1 ($10.00)!
        XCTAssertEqual(currentConn.lastObservation?.balance(for: "USD")?.totalBalance, Decimal(50))

        try? FileManager.default.removeItem(at: tempDir)
    }
}
