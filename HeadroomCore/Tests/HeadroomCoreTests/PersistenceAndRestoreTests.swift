import XCTest
@testable import HeadroomCore

final class PersistenceAndRestoreTests: XCTestCase {

    func testPrivatePermissionsCoverWalletRecoveryAndBackups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = AppStorageManager(storageDirectory: directory)

        try storage.save(StoredData())
        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: storage.storeFileURL), 0o600)

        let intent = PendingOperationIntent(
            connectionId: ConnectionID(), generationId: ConnectionGenerationID(),
            credentialId: ConnectionID(), kind: .add
        )
        try storage.savePendingIntent(intent)
        XCTAssertEqual(try permissions(at: storage.recoveryFileURL), 0o600)

        // Replacement must not inherit a previous file's broader permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storage.storeFileURL.path)
        try storage.save(StoredData())
        XCTAssertEqual(try permissions(at: storage.storeFileURL), 0o600)

        try Data("synthetic corrupt wallet".utf8).write(to: storage.storeFileURL)
        let backup = try storage.backupCorruptFile()
        XCTAssertEqual(try permissions(at: backup), 0o600)
        XCTAssertEqual(try Data(contentsOf: backup), Data("synthetic corrupt wallet".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".tmp.") }, "Successful writes must leave no temporary artifacts")
    }

    func testLegacyArtifactsAreRestrictedWithoutChangingTheirContents() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: directory) }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let originals: [String: Data] = [
            AppStorageManager.storeFileName: try encoder.encode(StoredData()),
            AppStorageManager.recoveryFileName: Data("[]".utf8),
            "store.corrupted.synthetic.bak": Data("synthetic backup".utf8),
            ".tmp.synthetic": Data("synthetic interrupted write".utf8)
        ]
        for (name, data) in originals {
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            try manager.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)
        }

        let storage = AppStorageManager(storageDirectory: directory)
        _ = storage.load()
        XCTAssertFalse(storage.isBlocked)
        XCTAssertTrue(storage.loadPendingIntents().isEmpty)
        XCTAssertEqual(try permissions(at: directory), 0o700)
        for (name, original) in originals {
            let url = directory.appendingPathComponent(name)
            XCTAssertEqual(try permissions(at: url), 0o600, name)
            XCTAssertEqual(try Data(contentsOf: url), original, "Permission repair must preserve \(name)")
        }
    }

    func testSymlinkStorageDirectoryBlocksWithoutChangingTargetPermissions() throws {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: parent) }
        let target = parent.appendingPathComponent("target")
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        let linkedDirectory = parent.appendingPathComponent("linked-storage")
        try manager.createSymbolicLink(at: linkedDirectory, withDestinationURL: target)

        let storage = AppStorageManager(storageDirectory: linkedDirectory)
        XCTAssertTrue(storage.isBlocked)
        _ = storage.load()
        XCTAssertTrue(storage.isBlocked)
        XCTAssertThrowsError(try storage.save(StoredData()))
        XCTAssertEqual(try permissions(at: target), 0o755)
        XCTAssertTrue(try manager.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testSymlinkWalletBlocksWithoutReadingOrChangingExternalFile() throws {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: parent) }
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("external-synthetic.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode(StoredData(connections: [Connection(providerId: .deepseek, userLabel: "Synthetic external")]))
        try original.write(to: target)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        let directory = parent.appendingPathComponent("storage")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: directory.appendingPathComponent(AppStorageManager.storeFileName), withDestinationURL: target)

        let storage = AppStorageManager(storageDirectory: directory)
        XCTAssertTrue(storage.load().connections.isEmpty)
        XCTAssertTrue(storage.isBlocked)
        XCTAssertThrowsError(try storage.save(StoredData()))
        XCTAssertEqual(try permissions(at: target), 0o644)
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    private func permissions(at url: URL) throws -> Int {
        let value = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        return value.intValue & 0o7777
    }

    func testAtomicSaveAndRestartRetention() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let conn1ID = ConnectionID()
        let conn2ID = ConnectionID()

        let conn1 = Connection(
            id: conn1ID,
            providerId: .deepseek,
            userLabel: "Primary DeepSeek",
            state: .ready
        )
        let conn2 = Connection(
            id: conn2ID,
            providerId: .deepseek,
            userLabel: "Secondary DeepSeek",
            state: .ready
        )

        let obs = WalletObservation(
            connectionId: conn1ID,
            generationId: conn1.generationId,
            isAvailable: true,
            balances: [
                CurrencyBalance(
                    currency: "USD",
                    totalBalance: Decimal(string: "15.0000")!,
                    grantedBalance: Decimal(0),
                    toppedUpBalance: Decimal(string: "15.0000")!
                )
            ]
        )

        let initialData = StoredData(
            version: 1,
            connections: [conn1, conn2],
            observations: [obs],
            updatedAt: Date()
        )

        try storage.save(initialData)

        // Simulate app restart by creating a new storage instance pointing to the same directory
        let restartedStorage = AppStorageManager(storageDirectory: tempDir)
        let loadedData = restartedStorage.load()

        XCTAssertEqual(loadedData.connections.count, 2)
        XCTAssertEqual(loadedData.connections[0].id, conn1ID)
        XCTAssertEqual(loadedData.connections[0].userLabel, "Primary DeepSeek")
        XCTAssertEqual(loadedData.connections[1].id, conn2ID)
        XCTAssertEqual(loadedData.connections[1].userLabel, "Secondary DeepSeek")

        XCTAssertEqual(loadedData.observations.count, 1)
        XCTAssertEqual(loadedData.observations[0].connectionId, conn1ID)
        XCTAssertEqual(loadedData.observations[0].balances.first?.totalBalance, Decimal(15))

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCorruptStorageSafelyBacksUpAndRecovers() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        // Write intentionally invalid garbage bytes to store.json
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent(AppStorageManager.storeFileName)
        try Data("GARBAGE_NON_JSON_CORRUPT_CONTENT".utf8).write(to: storeURL)

        // Load storage
        let loaded = storage.load()

        // Invariant: Does not crash! Returns safe empty state
        XCTAssertEqual(loaded.connections.count, 0)
        XCTAssertEqual(loaded.observations.count, 0)

        XCTAssertTrue(storage.isBlocked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        try storage.resetStorageAfterVerifiedBackup()
        // Explicit recovery preserves original bytes in a verified backup.
        let dirContents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backupFile = dirContents.first { $0.contains("store.corrupted") && $0.hasSuffix(".bak") }
        XCTAssertNotNil(backupFile, "Corrupted file must be preserved as a backup for data recovery")

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRetentionPolicyPruning30Days() {
        let policy = RetentionPolicy(maxAgeDays: 30)
        let now = Date()

        let recentDate = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let oldDate = Calendar.current.date(byAdding: .day, value: -35, to: now)!

        let connId = ConnectionID()
        let genId = ConnectionGenerationID()

        let recentObs = WalletObservation(
            connectionId: connId,
            generationId: genId,
            isAvailable: true,
            balances: [],
            capturedAt: recentDate
        )

        let oldObs = WalletObservation(
            connectionId: connId,
            generationId: genId,
            isAvailable: true,
            balances: [],
            capturedAt: oldDate
        )

        let pruned = policy.prune(observations: [recentObs, oldObs], relativeTo: now)
        XCTAssertEqual(pruned.count, 1)
        XCTAssertEqual(pruned.first?.id, recentObs.id)
    }

    func testVersionedExportAndIsolatedRestoreNeverCreatesAuthenticatedStatus() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        let connId = ConnectionID()
        let originalConn = Connection(
            id: connId,
            providerId: .deepseek,
            userLabel: "Exported Conn",
            state: .ready // In export, it was ready
        )

        let originalObs = WalletObservation(
            connectionId: connId,
            generationId: originalConn.generationId,
            isAvailable: true,
            balances: [
                CurrencyBalance(
                    currency: "USD",
                    totalBalance: Decimal(string: "20.0000")!,
                    grantedBalance: Decimal(0),
                    toppedUpBalance: Decimal(string: "20.0000")!
                )
            ]
        )

        let stored = StoredData(
            version: 1,
            connections: [originalConn],
            observations: [originalObs],
            updatedAt: Date()
        )

        // Export data
        let exportData = try storage.exportSnapshot(data: stored)

        // Restore into a completely separate isolated storage directory
        let isolatedDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let isolatedStorage = AppStorageManager(storageDirectory: isolatedDir)

        let (importedConnections, importedObservations) = try isolatedStorage.importSnapshot(exportData)
        XCTAssertEqual(importedConnections.count, 1)
        XCTAssertEqual(importedObservations.count, 1)

        let restoredConn = importedConnections.first!
        let restoredObs = importedObservations.first!

        // CRITICAL INVARIANT: Import NEVER creates authenticated status from a key reference!
        // It must be placed in awaitingVerification state requiring local API key entry.
        if case .awaitingVerification(let reason) = restoredConn.state {
            XCTAssertEqual(reason, .importedFromBackup)
            XCTAssertTrue(reason.description.contains("API key setup"))
        } else {
            XCTFail("Imported connection must be awaitingVerification, but got \(restoredConn.state)")
        }

        // CRITICAL INVARIANT: Observations and historical balances are fully restored with remapped IDs!
        XCTAssertNotEqual(restoredConn.id, connId, "Imported connection ID must be remapped to fresh local ID")
        XCTAssertEqual(restoredObs.connectionId, restoredConn.id, "Remapped observation must match remapped connection")
        XCTAssertEqual(restoredObs.balance(for: "USD")?.totalBalance, Decimal(20))
        XCTAssertEqual(restoredConn.lastObservation?.balance(for: "USD")?.totalBalance, Decimal(20))

        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.removeItem(at: isolatedDir)
    }

    func testImportRejectsUnsupportedSchemaVersion() throws {
        let futureSnapshot = SnapshotDTO(
            schemaVersion: 999,
            exportedAt: Date(),
            connections: [],
            observations: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let futureData = try encoder.encode(futureSnapshot)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)

        XCTAssertThrowsError(try storage.importSnapshot(futureData)) { error in
            guard case StorageError.unsupportedSchemaVersion(let v) = error else {
                XCTFail("Expected unsupportedSchemaVersion error, got \(error)")
                return
            }
            XCTAssertEqual(v, 999)
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testLoadRejectsUnsupportedStoredDataVersion() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent(AppStorageManager.storeFileName)

        let unsupportedData = StoredData(version: 999, connections: [Connection(providerId: .deepseek, userLabel: "Test")], observations: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(unsupportedData).write(to: storeURL)

        let storage = AppStorageManager(storageDirectory: tempDir)
        let loaded = storage.load()

        // Invariant: Connections from future schema versions are NOT loaded into active state
        XCTAssertEqual(loaded.connections.count, 0)
        if case .unsupportedSchemaVersion(let v) = storage.lastError {
            XCTAssertEqual(v, 999)
        } else {
            XCTFail("Expected unsupportedSchemaVersion in lastError, got \(String(describing: storage.lastError))")
        }

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCorruptStorageCollisionSafeBackups() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = AppStorageManager(storageDirectory: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let storeURL = tempDir.appendingPathComponent(AppStorageManager.storeFileName)

        // First corruption
        try Data("GARBAGE_1".utf8).write(to: storeURL)
        _ = storage.load()
        try storage.resetStorageAfterVerifiedBackup()

        // Second corruption immediately after
        try Data("GARBAGE_2".utf8).write(to: storeURL)
        _ = storage.load()
        try storage.resetStorageAfterVerifiedBackup()

        let dirContents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let bakFiles = dirContents.filter { $0.hasSuffix(".bak") }
        XCTAssertGreaterThanOrEqual(bakFiles.count, 2, "Multiple corruptions must produce distinct, collision-safe .bak files")

        try? FileManager.default.removeItem(at: tempDir)
    }
}
