import Foundation

public enum StorageError: Error, LocalizedError, Equatable {
    case fileTooLarge(size: Int)
    case unsupportedSchemaVersion(version: Int)
    case corruptedData
    case atomicWriteFailed
    case storageBlocked(reason: StorageBlockedReason)
    case backupVerificationFailed
    case corruptPreservationFailed(String)
    case invalidSnapshot(reason: String)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let size):
            return "Imported file exceeds maximum allowed size (\(size) bytes)."
        case .unsupportedSchemaVersion(let version):
            return "Unsupported storage schema version: \(version)."
        case .corruptedData:
            return "Corrupted data encountered in local storage."
        case .atomicWriteFailed:
            return "Atomic disk write failed."
        case .storageBlocked(let reason):
            return "Storage is blocked: \(reason.localizedDescription)"
        case .backupVerificationFailed:
            return "Failed to verify backup copy of storage file."
        case .corruptPreservationFailed(let msg):
            return "Failed to preserve corrupted data backup: \(msg)"
        case .invalidSnapshot(let reason):
            return "Invalid snapshot bundle: \(reason)."
        }
    }
}

public final class AppStorageManager: @unchecked Sendable {
    public static let storeFileName = "store.json"
    public static let recoveryFileName = "recovery.json"
    public static let maxImportSizeBytes = 5 * 1024 * 1024 // 5 MB

    public let storageDirectory: URL
    public let storeFileURL: URL
    public let recoveryFileURL: URL
    private let retentionPolicy: RetentionPolicy
    public private(set) var lastError: StorageError?
    public private(set) var status: StorageStatus = .uninitialized

    public var isBlocked: Bool {
        if case .blocked = status { return true }
        return false
    }

    public init(storageDirectory: URL, retentionPolicy: RetentionPolicy = RetentionPolicy()) {
        self.storageDirectory = storageDirectory
        self.storeFileURL = storageDirectory.appendingPathComponent(Self.storeFileName)
        self.recoveryFileURL = storageDirectory.appendingPathComponent(Self.recoveryFileName)
        self.retentionPolicy = retentionPolicy

        do {
            try preparePrivateStorage()
        } catch {
            let reason = StorageBlockedReason.readFailed("Local storage permissions could not be secured.")
            status = .blocked(reason)
            lastError = .storageBlocked(reason: reason)
        }
    }

    public static func defaultStorageDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(Bundle.main.bundleIdentifier ?? "org.headroom", isDirectory: true)
    }

    public func load() -> StoredData {
        lastError = nil
        let data: Data
        do {
            try preparePrivateStorage()
            data = try Data(contentsOf: storeFileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            status = .uninitialized
            return StoredData()
        } catch {
            let reason = StorageBlockedReason.readFailed("Try loading again when storage is available.")
            status = .blocked(reason)
            lastError = .storageBlocked(reason: reason)
            return StoredData()
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let stored = try decoder.decode(StoredData.self, from: data)

            // Strictly validate schema version: reject future schema versions and lock store
            guard stored.version == StoredData.currentVersion else {
                let reason = StorageBlockedReason.unsupportedSchemaVersion(stored.version)
                status = .blocked(reason)
                let err = StorageError.unsupportedSchemaVersion(version: stored.version)
                lastError = err
                // Return version indicator with empty active collections
                return StoredData(version: stored.version, connections: [], observations: [])
            }

            status = .healthy
            var result = stored
            result = applyingRetention(to: result)
            return result
        } catch {
            // Check if raw JSON had a future version before treating as corrupt data
            if let jsonObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let rawVersion = jsonObj["version"] as? Int,
               rawVersion != StoredData.currentVersion {
                let reason = StorageBlockedReason.unsupportedSchemaVersion(rawVersion)
                status = .blocked(reason)
                lastError = StorageError.unsupportedSchemaVersion(version: rawVersion)
                return StoredData(version: rawVersion, connections: [], observations: [])
            }

            // Loading never discards or moves rejected data. Recovery is an explicit action.
            let reason = StorageBlockedReason.corruptData("The original file is preserved.")
            status = .blocked(reason)
            lastError = .storageBlocked(reason: reason)
            return StoredData()
        }
    }

    public var shouldSimulateWriteFailure: Bool = false
    public var writeFailureProbe: (@Sendable () -> Bool)?
    public var shouldSimulateRecoveryWriteFailure: Bool = false

    public func save(_ data: StoredData) throws {
        if case .blocked(let reason) = status {
            throw StorageError.storageBlocked(reason: reason)
        }
        if shouldSimulateWriteFailure || writeFailureProbe?() == true {
            throw StorageError.atomicWriteFailed
        }
        var copy = data
        copy.updatedAt = Date()
        copy = applyingRetention(to: copy)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encodedData = try encoder.encode(copy)

        try atomicWrite(data: encodedData, to: storeFileURL)
    }

    private func atomicWrite(data: Data, to destinationURL: URL) throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        let tempURL = parentDir.appendingPathComponent(".tmp.\(UUID().uuidString)")
        do {
            try preparePrivateStorage()
            // The private parent directory also protects Foundation's intermediate atomic-write file.
            try data.write(to: tempURL, options: .atomic)
            try restrictPrivateFile(at: tempURL)
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
            // Replacement can retain the destination's old metadata, so enforce this after replacement too.
            try restrictPrivateFile(at: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw StorageError.atomicWriteFailed
        }
    }

    private func preparePrivateStorage() throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let attributes = try manager.attributesOfItem(atPath: storageDirectory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw StorageError.atomicWriteFailed
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storageDirectory.path)

        // Repair legacy files as well as new writes. Only app-owned artifact names are touched.
        for fileURL in try manager.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: nil) {
            let name = fileURL.lastPathComponent
            if name == Self.storeFileName || name == Self.recoveryFileName
                || (name.hasPrefix("store.corrupted.") && name.hasSuffix(".bak"))
                || name.hasPrefix(".tmp.") {
                try restrictPrivateFile(at: fileURL)
            }
        }
    }

    private func restrictPrivateFile(at url: URL) throws {
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        // Never chmod or read through a substituted symlink, directory or special file.
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StorageError.atomicWriteFailed
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @discardableResult
    public func backupCorruptFile() throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = storageDirectory.appendingPathComponent("store.corrupted.\(timestamp)-\(UUID().uuidString).bak")
        do {
            try preparePrivateStorage()
            try FileManager.default.copyItem(at: storeFileURL, to: backupURL)
            try restrictPrivateFile(at: backupURL)
            guard try Data(contentsOf: storeFileURL) == Data(contentsOf: backupURL) else {
                throw StorageError.backupVerificationFailed
            }
            return backupURL
        } catch {
            throw StorageError.corruptPreservationFailed("Backup could not be verified. The original file is preserved.")
        }
    }

    public func resetStorageAfterVerifiedBackup() throws {
        // A damaged journal cannot safely be discarded: it may be the only credential identity record.
        _ = loadPendingIntents()
        if case .blocked(.recoveryJournalUnreadable) = status {
            throw StorageError.storageBlocked(reason: .recoveryJournalUnreadable)
        }
        do {
            _ = try Data(contentsOf: storeFileURL)
            _ = try backupCorruptFile()
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A genuinely absent store needs no backup.
        } catch {
            throw StorageError.corruptPreservationFailed("The original file could not be preserved.")
        }
        let priorStatus = status
        status = .uninitialized
        do {
            try save(StoredData())
            status = .healthy
            lastError = nil
        } catch {
            status = priorStatus
            throw error
        }
    }

    private func applyingRetention(to data: StoredData) -> StoredData {
        var copy = data
        // Retain the latest known reading even when older than the rolling history window.
        // This keeps the displayed cached reading, export, and restart graph in agreement.
        let latestIDs = Set(copy.connections.compactMap { $0.lastObservation?.id })
        let recentIDs = Set(retentionPolicy.prune(observations: copy.observations).map(\.id))
        copy.observations = copy.observations.filter { latestIDs.contains($0.id) || recentIDs.contains($0.id) }
        for connection in copy.connections {
            if let latest = connection.lastObservation, !copy.observations.contains(where: { $0.id == latest.id }) {
                copy.observations.append(latest)
            }
        }
        return copy
    }

    private func requireWritableJournal() throws {
        if case .blocked(let reason) = status { throw StorageError.storageBlocked(reason: reason) }
        if shouldSimulateRecoveryWriteFailure { throw StorageError.atomicWriteFailed }
    }

    // MARK: - Pending Operation Intent Journal

    public func loadPendingIntents() -> [PendingOperationIntent] {
        do {
            try preparePrivateStorage()
            let data = try Data(contentsOf: recoveryFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([PendingOperationIntent].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            status = .blocked(.recoveryJournalUnreadable)
            lastError = .storageBlocked(reason: .recoveryJournalUnreadable)
            return []
        }
    }

    public func savePendingIntent(_ intent: PendingOperationIntent) throws {
        try requireWritableJournal()
        var intents = loadPendingIntents()
        try requireWritableJournal()
        if let idx = intents.firstIndex(where: { $0.id == intent.id }) {
            intents[idx] = intent
        } else {
            intents.append(intent)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(intents)
        try atomicWrite(data: data, to: recoveryFileURL)
    }

    public func removePendingIntent(id: UUID) throws {
        try requireWritableJournal()
        var intents = loadPendingIntents()
        try requireWritableJournal()
        intents.removeAll { $0.id == id }
        if intents.isEmpty {
            do { try FileManager.default.removeItem(at: recoveryFileURL) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
            catch { throw StorageError.atomicWriteFailed }
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(intents)
            try atomicWrite(data: data, to: recoveryFileURL)
        }
    }

    // MARK: - Export and Import (Credential-Free)

    public func exportSnapshot(data: StoredData) throws -> Data {
        let snapshot = SnapshotDTO.from(connections: data.connections, observations: data.observations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    public func importSnapshot(_ data: Data) throws -> (connections: [Connection], observations: [WalletObservation]) {
        if case .blocked(let reason) = status {
            throw StorageError.storageBlocked(reason: reason)
        }
        if data.count > Self.maxImportSizeBytes {
            throw StorageError.fileTooLarge(size: data.count)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot: SnapshotDTO
        do {
            snapshot = try decoder.decode(SnapshotDTO.self, from: data)
        } catch {
            throw StorageError.invalidSnapshot(reason: "Invalid snapshot JSON structure")
        }

        // Strict schema version: must match current version exactly (reject <= 0 and > 1)
        guard snapshot.schemaVersion == SnapshotDTO.currentSchemaVersion else {
            throw StorageError.unsupportedSchemaVersion(version: snapshot.schemaVersion)
        }

        // 1. Validate connection IDs uniqueness
        guard snapshot.connections.allSatisfy({ UUID(uuidString: $0.id) != nil }),
              snapshot.observations.allSatisfy({ UUID(uuidString: $0.id) != nil && UUID(uuidString: $0.connectionId) != nil }) else {
            throw StorageError.invalidSnapshot(reason: "Invalid record identity")
        }
        let rawConnIDs = snapshot.connections.map { $0.id.lowercased() }
        guard Set(rawConnIDs).count == rawConnIDs.count else {
            throw StorageError.invalidSnapshot(reason: "Duplicate connection ID detected in snapshot")
        }

        // 2. Validate observation IDs uniqueness
        let rawObsIDs = snapshot.observations.map { $0.id.lowercased() }
        guard Set(rawObsIDs).count == rawObsIDs.count else {
            throw StorageError.invalidSnapshot(reason: "Duplicate observation ID detected in snapshot")
        }

        // 3. Validate orphan observations
        let connIDSet = Set(rawConnIDs)
        for obs in snapshot.observations {
            guard connIDSet.contains(obs.connectionId.lowercased()) else {
                throw StorageError.invalidSnapshot(reason: "Observation references missing connection")
            }
        }

        // 4. Validate dates and timestamps
        let now = Date()
        let maxAllowedFuture = now.addingTimeInterval(300) // 5 minutes clock skew allowance
        var connCreatedAtMap: [String: Date] = [:]

        for connDTO in snapshot.connections {
            guard connDTO.createdAt <= connDTO.updatedAt else {
                throw StorageError.invalidSnapshot(reason: "Inverted connection timestamps: createdAt is after updatedAt")
            }
            guard connDTO.updatedAt <= maxAllowedFuture,
                  connDTO.createdAt <= maxAllowedFuture,
                  [connDTO.lastAttemptedRefresh, connDTO.lastSuccessfulRefresh].compactMap({ $0 }).allSatisfy({
                      $0 >= connDTO.createdAt.addingTimeInterval(-300) && $0 <= maxAllowedFuture
                  }) else {
                throw StorageError.invalidSnapshot(reason: "Inconsistent connection dates")
            }
            connCreatedAtMap[connDTO.id.lowercased()] = connDTO.createdAt
        }

        for obsDTO in snapshot.observations {
            guard obsDTO.capturedAt <= maxAllowedFuture else {
                throw StorageError.invalidSnapshot(reason: "Observation timestamp is in the future")
            }
            if let connCreated = connCreatedAtMap[obsDTO.connectionId.lowercased()] {
                guard obsDTO.capturedAt >= connCreated.addingTimeInterval(-300) else {
                    throw StorageError.invalidSnapshot(reason: "Observation captured before connection was created")
                }
            }
        }

        // 5. Remap all foreign IDs to brand new local IDs to guarantee complete isolation
        guard snapshot.exportedAt <= maxAllowedFuture else {
            throw StorageError.invalidSnapshot(reason: "Export timestamp is in the future")
        }
        var foreignToLocalConnMap: [String: (localConnId: ConnectionID, localCredId: ConnectionID, generation: ConnectionGenerationID, provider: ProviderID, label: String, created: Date, updated: Date, lastAttempt: Date?, lastSuccess: Date?)] = [:]

        for dto in snapshot.connections {
            guard UUID(uuidString: dto.id) != nil,
                  let provider = ProviderID(rawValue: dto.providerId) else {
                throw StorageError.invalidSnapshot(reason: "Invalid connection metadata")
            }
            let localConnId = ConnectionID()
            let localCredId = ConnectionID()
            foreignToLocalConnMap[dto.id.lowercased()] = (
                localConnId: localConnId,
                localCredId: localCredId,
                generation: ConnectionGenerationID(),
                provider: provider,
                label: dto.userLabel,
                created: dto.createdAt,
                updated: dto.updatedAt,
                lastAttempt: dto.lastAttemptedRefresh,
                lastSuccess: dto.lastSuccessfulRefresh
            )
        }

        var restoredObservations: [WalletObservation] = []
        var observationsByLocalConnId: [ConnectionID: [WalletObservation]] = [:]

        for obsDTO in snapshot.observations {
            guard UUID(uuidString: obsDTO.id) != nil,
                  let localMapping = foreignToLocalConnMap[obsDTO.connectionId.lowercased()] else {
                throw StorageError.invalidSnapshot(reason: "Invalid observation mapping")
            }

            let currencies = obsDTO.balances.map { $0.currency }
            guard Set(currencies).count == currencies.count,
                  currencies.allSatisfy({ $0.count == 3 && $0.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }) }) else {
                throw StorageError.invalidSnapshot(reason: "Invalid or duplicate currency code")
            }
            var parsedBalances: [CurrencyBalance] = []
            for balDTO in obsDTO.balances {
                let parsed = try CurrencyBalance.parseStrict(
                    currency: balDTO.currency,
                    totalString: balDTO.totalBalance,
                    grantedString: balDTO.grantedBalance,
                    toppedUpString: balDTO.toppedUpBalance
                )
                parsedBalances.append(parsed)
            }

            let newObsId = UUID()
            let observation = WalletObservation(
                id: newObsId,
                connectionId: localMapping.localConnId,
                generationId: localMapping.generation,
                isAvailable: obsDTO.isAvailable,
                balances: parsedBalances,
                capturedAt: obsDTO.capturedAt,
                sourceTimestamp: nil
            )
            restoredObservations.append(observation)
            observationsByLocalConnId[localMapping.localConnId, default: []].append(observation)
        }

        var restoredConnections: [Connection] = []
        for dto in snapshot.connections {
            guard let mapping = foreignToLocalConnMap[dto.id.lowercased()] else { continue }
            let matchingObs = observationsByLocalConnId[mapping.localConnId] ?? []
            let latestObs = matchingObs.max(by: { $0.capturedAt < $1.capturedAt })

            let connection = Connection(
                id: mapping.localConnId,
                credentialId: mapping.localCredId,
                generationId: mapping.generation,
                providerId: mapping.provider,
                userLabel: mapping.label,
                createdAt: mapping.created,
                updatedAt: mapping.updated,
                lastAttemptedRefresh: mapping.lastAttempt,
                lastSuccessfulRefresh: latestObs?.capturedAt ?? mapping.lastSuccess,
                lastObservation: latestObs,
                state: .awaitingVerification(reason: .importedFromBackup)
            )
            restoredConnections.append(connection)
        }

        return (restoredConnections, restoredObservations)
    }
}
