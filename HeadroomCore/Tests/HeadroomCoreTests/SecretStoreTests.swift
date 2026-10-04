import XCTest
@testable import HeadroomCore

final class SecretStoreTests: XCTestCase {

    func testSecretStoreOperations() throws {
        let store = InMemorySecretStore()
        let connectionId = ConnectionID()
        let secretMarker = "sk-test-secret-marker-12345"

        // 1. Initial state: no secret
        XCTAssertFalse(store.hasSecret(for: connectionId))
        XCTAssertNil(try store.readSecret(for: connectionId))

        // 2. Save secret
        try store.saveSecret(secretMarker, for: connectionId)
        XCTAssertTrue(store.hasSecret(for: connectionId))
        XCTAssertEqual(try store.readSecret(for: connectionId), secretMarker)

        // 3. Delete secret
        try store.deleteSecret(for: connectionId)
        XCTAssertFalse(store.hasSecret(for: connectionId))
        XCTAssertNil(try store.readSecret(for: connectionId))
    }

    func testCompensationCleansUpSecretOnStorageFailure() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)
        storage.shouldSimulateWriteFailure = true

        let mockTransport = MockNetworkTransport { _ in
            let response = HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        let mockClient = DeepSeekClient(transport: mockTransport)

        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: mockClient
            )
        }

        let secretMarker = "sk-test-compensation-key"
        do {
            try await coordinator.addConnection(provider: .deepseek, userLabel: "Test", apiKey: secretMarker)
            XCTFail("Expected storage failure")
        } catch {
            // Verification: Compensation must delete the secret from the secret store
            // So no orphan credentials remain in Keychain/SecretStore!
            let connections = await coordinator.connections
            XCTAssertTrue(connections.isEmpty, "Connection must not be saved if storage persistence fails")
            XCTAssertEqual(secretStore.count, 0, "All secrets must be purged from secretStore after compensation")
            XCTAssertTrue(storage.loadPendingIntents().isEmpty, "Pending intent journal must be settled after compensation")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testNoSecretMarkerInMetadataOrSnapshotOrExport() async throws {
        let secretStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let mockTransport = MockNetworkTransport { _ in
            let response = HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let validJSON = """
            {"is_available": true, "balance_infos": []}
            """
            return (Data(validJSON.utf8), response)
        }
        let mockClient = DeepSeekClient(transport: mockTransport)

        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage,
                deepSeekClient: mockClient
            )
        }

        let secretMarker = "SUPER_SECRET_TOKEN_DO_NOT_LEAK_9999"
        let conn = try await coordinator.addConnection(provider: .deepseek, userLabel: "Work", apiKey: secretMarker)

        // 1. Check Connection domain model
        let encoder = JSONEncoder()
        let connData = try encoder.encode(conn)
        let connString = String(data: connData, encoding: .utf8)!
        XCTAssertFalse(connString.contains(secretMarker), "Connection JSON representation must not contain secret")

        // 2. Check StoredData
        let storedData = storage.load()
        let storedJSON = try encoder.encode(storedData)
        let storedString = String(data: storedJSON, encoding: .utf8)!
        XCTAssertFalse(storedString.contains(secretMarker), "Persisted store.json must never contain secret")

        // 3. Check Exported Snapshot
        let exportData = try await coordinator.exportSnapshot()
        let exportString = String(data: exportData, encoding: .utf8)!
        XCTAssertFalse(exportString.contains(secretMarker), "Exported snapshot must never contain secret")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPlatformKeychainSecretStoreOperations() throws {
        // Isolated service name to ensure test isolation
        let testService = "com.headroom.test.keychain.\(UUID().uuidString)"
        let keychainStore = KeychainSecretStore(serviceName: testService)
        let testConnID = ConnectionID()
        let initialSecret = "sk-initial-secret-\(UUID().uuidString)"
        let updatedSecret = "sk-updated-secret-\(UUID().uuidString)"

        defer {
            try? keychainStore.deleteSecret(for: testConnID)
        }

        // 1. Save new secret
        try keychainStore.saveSecret(initialSecret, for: testConnID)
        XCTAssertTrue(keychainStore.hasSecret(for: testConnID))
        XCTAssertEqual(try keychainStore.readSecret(for: testConnID), initialSecret)

        // 2. Update existing secret (exercises safe SecItemUpdate without prior delete)
        try keychainStore.saveSecret(updatedSecret, for: testConnID)
        XCTAssertTrue(keychainStore.hasSecret(for: testConnID))
        XCTAssertEqual(try keychainStore.readSecret(for: testConnID), updatedSecret)

        // 3. Delete secret
        try keychainStore.deleteSecret(for: testConnID)
        XCTAssertFalse(keychainStore.hasSecret(for: testConnID))
        XCTAssertNil(try keychainStore.readSecret(for: testConnID))
    }

    func testSecretStoreDeleteFailurePropagatesError() async throws {
        let inMemoryStore = InMemorySecretStore()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let mockTransport = MockNetworkTransport { _ in
            let validJSON = "{\"is_available\": true, \"balance_infos\": []}"
            return (Data(validJSON.utf8), HTTPURLResponse(url: URL(string: "https://api.deepseek.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let mockClient = DeepSeekClient(transport: mockTransport)

        let coordinator = await MainActor.run {
            WalletCoordinator(
                secretStore: inMemoryStore,
                storageManager: storage,
                deepSeekClient: mockClient
            )
        }

        let conn = try await coordinator.addConnection(provider: .deepseek, userLabel: "To Delete", apiKey: "sk-del")
        let initialCount = await coordinator.connections.count
        XCTAssertEqual(initialCount, 1)

        // Simulate Keychain failure during deletion
        inMemoryStore.failDelete = true

        do {
            try await MainActor.run {
                try coordinator.removeConnection(id: conn.id)
            }
            XCTFail("Expected delete failure when SecretStore fails")
        } catch {
            // Connection state marked with keychainFailure rather than silent corruption
            let conns = await coordinator.connections
            let remainingConn = conns.first(where: { $0.id == conn.id })
            XCTAssertNotNil(remainingConn)
            if case .keychainFailure = remainingConn?.state {
                // Verified: state reflects keychain failure
            } else {
                XCTFail("Expected keychainFailure state, got \(String(describing: remainingConn?.state))")
            }
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRedirectRejectionInSecureTransport() {
        let transport = SecureURLSessionTransport()
        let originalURL = URL(string: "https://api.deepseek.com/user/balance")!
        let redirectURL = URL(string: "https://malicious-site.com/steal")!

        let response = HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": redirectURL.absoluteString]
        )!
        let newRequest = URLRequest(url: redirectURL)

        var passedRequest: URLRequest? = newRequest
        transport.urlSession(
            URLSession.shared,
            task: URLSession.shared.dataTask(with: originalURL),
            willPerformHTTPRedirection: response,
            newRequest: newRequest
        ) { request in
            passedRequest = request
        }

        XCTAssertNil(passedRequest, "Redirect must be strictly rejected (completionHandler(nil)) to protect credentials")
    }
}
