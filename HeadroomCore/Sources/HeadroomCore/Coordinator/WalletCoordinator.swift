import Foundation
import Combine

public enum CoordinatorError: Error, LocalizedError, Equatable {
    case demoModeActive
    case unsupportedProvider
    case missingCredential
    case invalidBudget
    case connectionNotFound
    case pendingRecovery
    case rateLimited(retryAfter: Date)
    case secretStoreError(description: String)
    case storageError(description: String)

    public var errorDescription: String? {
        switch self {
        case .demoModeActive:
            return "Modifications are disabled in Demo Mode. Exit Demo Mode to manage real accounts."
        case .unsupportedProvider:
            return "Provider is not yet supported in this version."
        case .missingCredential:
            return "No API key found for this connection."
        case .invalidBudget:
            return "Enter a positive monthly budget in USD, or leave it blank."
        case .connectionNotFound:
            return "Connection not found."
        case .pendingRecovery:
            return "Finish account recovery before changing this connection."
        case .rateLimited(let retryAfter):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return "Provider rate limit in effect until \(formatter.localizedString(for: retryAfter, relativeTo: Date()))."
        case .secretStoreError(let desc):
            return "Keychain error: \(desc)"
        case .storageError(let desc):
            return "Storage error: \(desc)"
        }
    }
}

public enum AcquisitionTrigger: Sendable, Equatable {
    case scheduledTimer
    case appResume
    case manualUserRefresh
    case explicitVerification
    case explicitRecovery
}

private enum APIReading: Sendable {
    case wallet(WalletObservation)
    case cost(APICostObservation)
}

private struct ActiveOperation {
    let operationId: UUID
    let generationId: ConnectionGenerationID
    let task: Task<APIReading, Error>
}

@MainActor
public final class WalletCoordinator: ObservableObject {
    @Published public private(set) var connections: [Connection] = []
    @Published public private(set) var observations: [WalletObservation] = []
    @Published public private(set) var isDemoMode: Bool = false
    @Published public private(set) var isFixtureMode: Bool = false
    @Published public private(set) var isRefreshing: Bool = false
    @Published public var lastErrorMessage: String?
    @Published public private(set) var storageStatus: StorageStatus = .uninitialized
    @Published public private(set) var pendingIntents: [PendingOperationIntent] = []

    public var isStorageBlocked: Bool {
        storageManager.isBlocked
    }

    public let secretStore: SecretStoreProtocol
    public let storageManager: AppStorageManager
    public let deepSeekClient: DeepSeekClient
    public let openAICostClient: OpenAICostClient
    public let anthropicCostClient: AnthropicCostClient
    private let clock: @Sendable () -> Date

    private var activeOperations: [ConnectionID: ActiveOperation] = [:]
    private var demoSessionId: UUID = UUID()
    private var timerCancellable: AnyCancellable?
    private var schedulingActive = true
    public static let autoRefreshIntervalSeconds: TimeInterval = 300 // 5 minutes

    public init(
        secretStore: SecretStoreProtocol,
        storageManager: AppStorageManager,
        deepSeekClient: DeepSeekClient? = nil,
        openAICostClient: OpenAICostClient? = nil,
        anthropicCostClient: AnthropicCostClient? = nil,
        isFixtureMode: Bool = false,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.storageManager = storageManager
        self.deepSeekClient = deepSeekClient ?? DeepSeekClient(dateProvider: clock)
        self.openAICostClient = openAICostClient ?? OpenAICostClient(dateProvider: clock)
        self.anthropicCostClient = anthropicCostClient ?? AnthropicCostClient(dateProvider: clock)
        self.isFixtureMode = isFixtureMode
        self.clock = clock

        loadStoredData()
        startAutoRefreshTimer()
    }

    // MARK: - Active Data Surfaces (Demo vs Live Isolation)

    public var activeConnections: [Connection] {
        if isDemoMode {
            return DemoFixtures.makeDemoConnections()
        }
        return connections
    }

    public var activeObservations: [WalletObservation] {
        if isDemoMode {
            return DemoFixtures.makeDemoObservations()
        }
        return observations
    }

    public func observation(for connectionId: ConnectionID) -> WalletObservation? {
        if isDemoMode {
            return DemoFixtures.makeDemoObservations().first { $0.connectionId == connectionId }
        }
        return observations.first { $0.connectionId == connectionId }
    }

    // MARK: - Controlled Demo Mode Transition (T02-R01)

    public func setDemoMode(_ enabled: Bool) {
        guard isDemoMode != enabled else { return }

        if enabled {
            // Entering demo mode: invalidate and cancel all pending real network operations
            demoSessionId = UUID()
            for (_, op) in activeOperations {
                op.task.cancel()
            }
            activeOperations.removeAll()
            isRefreshing = false
            isDemoMode = true
        } else {
            // Exiting demo mode: restore real store from disk cleanly
            isDemoMode = false
            demoSessionId = UUID()
            loadStoredData()
        }
    }

    public func toggleDemoMode() {
        setDemoMode(!isDemoMode)
    }

    // MARK: - Data Loading and Persistence

    public func loadStoredData() {
        for operation in activeOperations.values { operation.task.cancel() }
        activeOperations.removeAll()
        isRefreshing = false
        let stored = storageManager.load()
        self.pendingIntents = storageManager.loadPendingIntents()
        self.storageStatus = storageManager.status
        if let err = storageManager.lastError {
            self.lastErrorMessage = err.localizedDescription
            self.connections = []
            self.observations = []
            return
        }
        self.connections = stored.connections
        self.observations = stored.observations
        self.lastErrorMessage = nil

        resolvePendingOperations()
        normalizeInterruptedVerification()
    }

    private func persistCurrentState() throws {
        let data = StoredData(
            version: StoredData.currentVersion,
            connections: self.connections,
            observations: self.observations,
            pendingIntents: self.pendingIntents,
            updatedAt: clock()
        )
        try storageManager.save(data)
    }

    // MARK: - Recovery Journal Resolution (Repair A)

    /// Replays only durable, already-authorized credential operations. No network work occurs here.
    public func resolvePendingOperations() {
        do { try recoverPendingOperations(retryPaused: false) }
        catch { lastErrorMessage = "Account recovery is incomplete. Retry when saved data and credentials are available." }
    }

    public func retryRecovery() throws {
        try recoverPendingOperations(retryPaused: true)
    }

    private func recoverPendingOperations(retryPaused: Bool) throws {
        guard !isDemoMode else { throw CoordinatorError.demoModeActive }
        try requireWritableStorage()
        pendingIntents = storageManager.loadPendingIntents()
        try requireWritableStorage()
        var firstError: Error?
        for intent in pendingIntents {
            cancelOperation(for: intent.connectionId)
            do {
                switch intent.kind {
                case .add, .replaceCredential:
                    let committed = connections.contains {
                        $0.id == intent.connectionId && $0.credentialId == intent.credentialId && $0.generationId == intent.generationId
                    }
                    // A crash can occur immediately after saving a key or committing metadata,
                    // before updating the journal stage. Committed bindings are authoritative.
                    if committed {
                        if let oldID = intent.oldCredentialId, oldID != intent.credentialId {
                            try secretStore.deleteSecret(for: oldID)
                        }
                    } else {
                        try secretStore.deleteSecret(for: intent.credentialId)
                    }
                    try storageManager.removePendingIntent(id: intent.id)
                case .delete:
                    try completeDeletion(intent)
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        pendingIntents = storageManager.loadPendingIntents()
        storageStatus = storageManager.status
        if let firstError { throw firstError }
        try requireWritableStorage()
        if retryPaused { try retryPausedConnections() }
        normalizeInterruptedVerification()
        lastErrorMessage = nil
    }

    public func hasPendingIntent(for connectionId: ConnectionID) -> Bool {
        pendingIntents.contains { $0.connectionId == connectionId }
    }

    private func requireWritableStorage() throws {
        if case .blocked(let reason) = storageManager.status {
            storageStatus = storageManager.status
            throw StorageError.storageBlocked(reason: reason)
        }
    }

    private func requireMutationAllowed(for connectionId: ConnectionID? = nil) throws {
        guard !isDemoMode else { throw CoordinatorError.demoModeActive }
        try requireWritableStorage()
        pendingIntents = storageManager.loadPendingIntents()
        try requireWritableStorage()
        if let connectionId, hasPendingIntent(for: connectionId) { throw CoordinatorError.pendingRecovery }
    }

    private func cancelOperation(for id: ConnectionID) {
        activeOperations[id]?.task.cancel()
        activeOperations.removeValue(forKey: id)
        isRefreshing = !activeOperations.isEmpty
    }

    private func persistStaged(connections stagedConnections: [Connection], observations stagedObservations: [WalletObservation]) throws {
        try storageManager.save(StoredData(
            connections: stagedConnections, observations: stagedObservations,
            pendingIntents: pendingIntents, updatedAt: clock()
        ))
        connections = stagedConnections
        observations = stagedObservations
    }

    private func recordIntent(_ intent: PendingOperationIntent) throws {
        try storageManager.savePendingIntent(intent)
        pendingIntents = storageManager.loadPendingIntents()
        try requireWritableStorage()
    }

    private func settleIntent(_ intent: PendingOperationIntent) throws {
        try storageManager.removePendingIntent(id: intent.id)
        pendingIntents = storageManager.loadPendingIntents()
        try requireWritableStorage()
    }

    private func compensateUncommittedCredential(_ intent: PendingOperationIntent) {
        do {
            try secretStore.deleteSecret(for: intent.credentialId)
            try settleIntent(intent)
        } catch {
            // The original intent is sufficient even if another journal write fails.
            pendingIntents = storageManager.loadPendingIntents()
            lastErrorMessage = "A credential change needs recovery. Use Retry Recovery to finish cleanup."
        }
    }

    private func retryPausedConnections() throws {
        var staged = connections
        var changed = false
        for index in staged.indices where !hasPendingIntent(for: staged[index].id) {
            switch staged[index].state {
            case .keychainFailure:
                if let key = try secretStore.readSecret(for: staged[index].credentialId), !key.isEmpty {
                    staged[index].state = .unavailable
                } else {
                    staged[index].state = .awaitingVerification(reason: .keyRequiresVerification)
                }
                changed = true
            case .persistenceFailure:
                staged[index].state = staged[index].lastObservation == nil && staged[index].lastAPICostObservation == nil
                    ? .unavailable : .ready
                changed = true
            default: break
            }
        }
        if changed { try persistStaged(connections: staged, observations: observations) }
    }

    private func normalizeInterruptedVerification() {
        guard !storageManager.isBlocked, !isDemoMode else { return }
        var staged = connections
        var changed = false
        for index in staged.indices where staged[index].state == .verifying && !hasPendingIntent(for: staged[index].id) && activeOperations[staged[index].id] == nil {
            do {
                if let key = try secretStore.readSecret(for: staged[index].credentialId), !key.isEmpty {
                    staged[index].state = .unavailable
                } else {
                    staged[index].state = .awaitingVerification(reason: .keyRequiresVerification)
                }
            } catch { staged[index].state = .keychainFailure }
            changed = true
        }
        if changed {
            do { try persistStaged(connections: staged, observations: observations) }
            catch { lastErrorMessage = "The interrupted connection could not be recovered. Retry loading saved data." }
        }
    }

    private func completeDeletion(_ intent: PendingOperationIntent) throws {
        // Retain a paused connection until both credential removal and metadata removal succeed.
        // The journal is also a tombstone if the process stops between those writes.
        if let index = connections.firstIndex(where: { $0.id == intent.connectionId }) {
            var staged = connections
            staged[index].state = .keychainFailure
            try persistStaged(connections: staged, observations: observations)
        }
        try secretStore.deleteSecret(for: intent.credentialId)
        try persistStaged(
            connections: connections.filter { $0.id != intent.connectionId },
            observations: observations.filter { $0.connectionId != intent.connectionId }
        )
        try settleIntent(intent)
    }

    // MARK: - Centralized Acquisition Eligibility (Repair D)

    public func isConnectionEligibleForRefresh(_ connection: Connection, trigger: AcquisitionTrigger) -> Bool {
        guard !isDemoMode, schedulingActive else { return false }
        guard !storageManager.isBlocked else { return false }

        // If there is an unresolved pending intent for this connection, block normal refresh
        if hasPendingIntent(for: connection.id) {
            return false
        }

        switch connection.state {
        case .ready:
            return true
        case .offline, .timeout, .malformedResponse, .serverError, .unavailable:
            return true
        case .verifying:
            return false
        case .rateLimited(let retryAfter):
            return clock() >= retryAfter
        case .authFailed:
            return trigger == .explicitVerification
        case .awaitingVerification:
            return trigger == .explicitVerification
        case .keychainFailure, .persistenceFailure:
            return trigger == .explicitRecovery
        case .notConfigured:
            return false
        }
    }

    // MARK: - Connection Lifecycle and Recovery (T02-R01, T02-R02, T02-R03)

    @discardableResult
    public func addConnection(provider: ProviderID, userLabel: String, apiKey: String, monthlyBudget: Decimal? = nil) async throws -> Connection {
        try requireMutationAllowed()
        guard provider == .deepseek || provider == .openai || provider == .anthropic else { throw CoordinatorError.unsupportedProvider }
        try validateBudget(monthlyBudget)
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else { throw CoordinatorError.missingCredential }
        let connection = Connection(
            id: ConnectionID(), credentialId: ConnectionID(), generationId: ConnectionGenerationID(),
            providerId: provider, userLabel: userLabel, createdAt: clock(), updatedAt: clock(), monthlyBudget: monthlyBudget, state: .verifying
        )
        let intent = PendingOperationIntent(
            connectionId: connection.id, generationId: connection.generationId,
            credentialId: connection.credentialId, kind: .add, stage: .initiated,
            createdAt: clock(), updatedAt: clock()
        )
        try recordIntent(intent)
        do {
            try secretStore.saveSecret(cleanKey, for: connection.credentialId)
            try persistStaged(connections: connections + [connection], observations: observations)
        } catch {
            compensateUncommittedCredential(intent)
            throw error
        }
        // Failed journal settlement is visible and remains paused; committed metadata is kept.
        do { try settleIntent(intent) }
        catch {
            lastErrorMessage = "The connection was saved and needs recovery before it can refresh."
            throw error
        }
        await performVerification(for: connection.id, generationId: connection.generationId, apiKey: cleanKey)
        return connections.first { $0.id == connection.id } ?? connection
    }

    public func updateConnection(id: ConnectionID, userLabel: String, newApiKey: String?, monthlyBudget: Decimal? = nil) async throws {
        try requireMutationAllowed(for: id)
        try validateBudget(monthlyBudget)
        guard let index = connections.firstIndex(where: { $0.id == id }) else { throw CoordinatorError.connectionNotFound }
        guard let cleanKey = newApiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanKey.isEmpty else {
            var staged = connections
            staged[index].userLabel = userLabel
            staged[index].monthlyBudget = monthlyBudget
            staged[index].updatedAt = clock()
            try persistStaged(connections: staged, observations: observations)
            return
        }
        let original = connections[index]
        guard original.providerId == .deepseek || original.providerId == .openai || original.providerId == .anthropic else { throw CoordinatorError.unsupportedProvider }
        cancelOperation(for: id)
        let intent = PendingOperationIntent(
            connectionId: id, generationId: ConnectionGenerationID(), credentialId: ConnectionID(),
            oldCredentialId: original.credentialId, kind: .replaceCredential, stage: .initiated,
            createdAt: clock(), updatedAt: clock()
        )
        try recordIntent(intent)
        var staged = connections
        staged[index].credentialId = intent.credentialId
        staged[index].generationId = intent.generationId
        staged[index].userLabel = userLabel
        staged[index].updatedAt = clock()
        staged[index].lastObservation = nil
        staged[index].lastAPICostObservation = nil
        staged[index].monthlyBudget = monthlyBudget
        staged[index].lastSuccessfulRefresh = nil
        staged[index].lastAttemptedRefresh = nil
        staged[index].state = .verifying
        do {
            try secretStore.saveSecret(cleanKey, for: intent.credentialId)
            try persistStaged(connections: staged, observations: observations.filter { $0.connectionId != id })
        } catch {
            compensateUncommittedCredential(intent)
            throw error
        }
        do {
            try secretStore.deleteSecret(for: original.credentialId)
            try settleIntent(intent)
        } catch {
            lastErrorMessage = "The new credential was saved. Retry Recovery to finish retiring the previous credential."
            throw error
        }
        await performVerification(for: id, generationId: intent.generationId, apiKey: cleanKey)
    }

    public func removeConnection(id: ConnectionID) throws {
        try requireMutationAllowed(for: id)
        guard let original = connections.first(where: { $0.id == id }) else { return }
        cancelOperation(for: id)
        let intent = PendingOperationIntent(
            connectionId: id, generationId: original.generationId, credentialId: original.credentialId,
            kind: .delete, stage: .initiated, createdAt: clock(), updatedAt: clock()
        )
        try recordIntent(intent)
        do { try completeDeletion(intent) }
        catch {
            pendingIntents = storageManager.loadPendingIntents()
            lastErrorMessage = "Account deletion is paused. Retry Recovery to finish removing the saved credential and account."
            throw error
        }
    }

    // MARK: - Coalesced, Generation-Safe Verification & Refresh (T02-R02, T02-R04)

    private func performVerification(
        for connectionId: ConnectionID,
        generationId: ConnectionGenerationID,
        apiKey: String
    ) async {
        guard !isDemoMode, schedulingActive, !storageManager.isBlocked, !hasPendingIntent(for: connectionId) else { return }
        let operationId = UUID()
        guard let provider = connections.first(where: { $0.id == connectionId })?.providerId else { return }
        let task = Task<APIReading, Error> {
            try await self.acquire(provider: provider, apiKey: apiKey, connectionId: connectionId, generationId: generationId)
        }

        activeOperations[connectionId] = ActiveOperation(
            operationId: operationId,
            generationId: generationId,
            task: task
        )

        do {
            let observation = try await task.value
            guard shouldApplyResult(connectionId: connectionId, generationId: generationId, operationId: operationId) else {
                return
            }
            cleanUpOperation(connectionId: connectionId, operationId: operationId)
            applySuccessfulReading(reading: observation, for: connectionId)
        } catch is CancellationError {
            cleanUpOperation(connectionId: connectionId, operationId: operationId)
        } catch let costError as APICostError {
            guard shouldApplyResult(connectionId: connectionId, generationId: generationId, operationId: operationId) else { return }
            cleanUpOperation(connectionId: connectionId, operationId: operationId)
            applyRefreshError(error: mappedCostError(costError), for: connectionId)
        } catch let deepSeekError as DeepSeekError {
            guard shouldApplyResult(connectionId: connectionId, generationId: generationId, operationId: operationId) else {
                return
            }
            cleanUpOperation(connectionId: connectionId, operationId: operationId)
            applyVerificationFailure(error: deepSeekError, for: connectionId)
        } catch {
            guard shouldApplyResult(connectionId: connectionId, generationId: generationId, operationId: operationId) else {
                return
            }
            cleanUpOperation(connectionId: connectionId, operationId: operationId)
            updateConnectionState(id: connectionId, state: .awaitingVerification(reason: .keyRequiresVerification))
        }
    }

    public func refresh(connectionId: ConnectionID, forced: Bool = false) async {
        // Zero network transport in demo mode
        guard !isDemoMode else { return }

        guard let conn = connections.first(where: { $0.id == connectionId }) else { return }

        let trigger: AcquisitionTrigger = forced ? .manualUserRefresh : .scheduledTimer
        guard isConnectionEligibleForRefresh(conn, trigger: trigger) else {
            return
        }

        // Coalescing: If task for current generation is already in flight, wait for it
        if let existing = activeOperations[connectionId], existing.generationId == conn.generationId {
            _ = try? await existing.task.value
            return
        }

        // Retrieve secret using the connection's staged credential identity
        let apiKey: String
        do {
            guard let saved = try secretStore.readSecret(for: conn.credentialId), !saved.isEmpty else {
                updateConnectionState(id: connectionId, state: .awaitingVerification(reason: .keyRequiresVerification))
                return
            }
            apiKey = saved
        } catch {
            updateConnectionState(id: connectionId, state: .keychainFailure)
            lastErrorMessage = "The saved credential could not be read. Retry Recovery when credentials are available."
            return
        }

        let generationId = conn.generationId
        let operationId = UUID()
        let task = Task<APIReading, Error> {
            try await self.acquire(provider: conn.providerId, apiKey: apiKey, connectionId: connectionId, generationId: generationId)
        }

        activeOperations[connectionId] = ActiveOperation(
            operationId: operationId,
            generationId: generationId,
            task: task
        )
        isRefreshing = true
        recordRefreshAttempt(for: connectionId)

        do {
            let observation = try await task.value
            guard shouldApplyResult(connectionId: connectionId, generationId: generationId, operationId: operationId) else {
                return
            }
            cleanUpOperation(connectionId: connectionId, operationId: operationId)
            applySuccessfulReading(reading: observation, for: connectionId)
        } catch is CancellationError {
            cleanUpOperation(connectionId: connectionId, operationId: operationId)
        } catch let costError as APICostError {
            guard shouldApplyResult(connectionId: connectionId, generationId: generationId, operationId: operationId) else { return }
            cleanUpOperation(connectionId: connectionId, operationId: operationId)
            applyRefreshError(error: mappedCostError(costError), for: connectionId)
        } catch let deepSeekError as DeepSeekError {
            guard shouldApplyResult(connectionId: connectionId, generationId: generationId, operationId: operationId) else {
                return
            }
            cleanUpOperation(connectionId: connectionId, operationId: operationId)
            applyRefreshError(error: deepSeekError, for: connectionId)
        } catch {
            guard shouldApplyResult(connectionId: connectionId, generationId: generationId, operationId: operationId) else {
                return
            }
            cleanUpOperation(connectionId: connectionId, operationId: operationId)
            updateConnectionState(id: connectionId, state: .offline(lastAttempt: clock()))
        }
    }

    public func refreshAll(forced: Bool = false) async {
        guard !isDemoMode else { return }
        let trigger: AcquisitionTrigger = forced ? .manualUserRefresh : .scheduledTimer

        for conn in connections {
            guard isConnectionEligibleForRefresh(conn, trigger: trigger) else {
                continue
            }
            await refresh(connectionId: conn.id, forced: forced)
        }
    }

    // MARK: - Generation and Operation Invariant Checks

    private func shouldApplyResult(
        connectionId: ConnectionID,
        generationId: ConnectionGenerationID,
        operationId: UUID
    ) -> Bool {
        // In demo mode or if demo was entered, live results must NOT commit
        guard !isDemoMode, schedulingActive, !storageManager.isBlocked, !hasPendingIntent(for: connectionId) else { return false }

        // Must still match current active operation slot
        guard let active = activeOperations[connectionId], active.operationId == operationId else {
            return false
        }

        // Connection must still exist and generation must match
        guard let current = connections.first(where: { $0.id == connectionId }),
              current.generationId == generationId else {
            return false
        }

        return true
    }

    private func cleanUpOperation(connectionId: ConnectionID, operationId: UUID) {
        if activeOperations[connectionId]?.operationId == operationId {
            activeOperations.removeValue(forKey: connectionId)
        }
        isRefreshing = !activeOperations.isEmpty
    }

    private func validateBudget(_ budget: Decimal?) throws {
        if let budget, budget.isNaN || budget <= 0 { throw CoordinatorError.invalidBudget }
    }

    private func acquire(provider: ProviderID, apiKey: String, connectionId: ConnectionID, generationId: ConnectionGenerationID) async throws -> APIReading {
        switch provider {
        case .deepseek:
            return .wallet(try await deepSeekClient.fetchBalance(apiKey: apiKey, connectionId: connectionId, generationId: generationId))
        case .openai:
            return .cost(try await openAICostClient.fetchCurrentMonthCost(adminAPIKey: apiKey, connectionId: connectionId, generationId: generationId))
        case .anthropic:
            return .cost(try await anthropicCostClient.fetchCurrentMonthCost(adminAPIKey: apiKey, connectionId: connectionId, generationId: generationId))
        default: throw CoordinatorError.unsupportedProvider
        }
    }

    private func mappedCostError(_ error: APICostError) -> DeepSeekError {
        switch error {
        case .authFailure(let code): return .authFailure(statusCode: code)
        case .rateLimited(let deadline): return .rateLimited(retryAfter: deadline)
        case .serverError(let code): return .serverError(statusCode: code)
        case .offline: return .offline
        case .timeout: return .timeout
        case .cancelled: return .cancelled
        case .responseTooLarge: return .responseTooLarge
        case .malformedResponse, .incompleteReport, .redirectRejected, .invalidHost: return .malformedResponse
        case .networkError: return .networkError
        }
    }

    // MARK: - State Update Helpers

    private func recordRefreshAttempt(for connectionId: ConnectionID) {
        guard let idx = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        connections[idx].lastAttemptedRefresh = clock()
    }

    private func applySuccessfulReading(reading: APIReading, for connectionId: ConnectionID) {
        guard let idx = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        let now = clock()

        connections[idx].lastSuccessfulRefresh = now
        switch reading {
        case .wallet(let observation):
            connections[idx].lastObservation = observation
            observations.removeAll { $0.id == observation.id || ($0.connectionId == connectionId && $0.capturedAt == observation.capturedAt) }
            observations.append(observation)
        case .cost(let observation):
            connections[idx].lastAPICostObservation = observation
        }
        connections[idx].state = .ready

        do {
            try persistCurrentState()
        } catch {
            connections[idx].state = .persistenceFailure
        }
    }

    private func applyRefreshError(error: DeepSeekError, for connectionId: ConnectionID) {
        guard let idx = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        let now = clock()
        connections[idx].lastAttemptedRefresh = now

        switch error {
        case .authFailure(let code):
            connections[idx].state = .authFailed(statusCode: code)
        case .rateLimited(let retryAfter):
            connections[idx].state = .rateLimited(retryAfter: retryAfter)
        case .offline:
            connections[idx].state = .offline(lastAttempt: now)
        case .timeout:
            connections[idx].state = .timeout
        case .malformedResponse, .missingRequiredField, .responseTooLarge:
            connections[idx].state = .malformedResponse
        case .serverError(let code):
            connections[idx].state = .serverError(statusCode: code)
        default:
            connections[idx].state = .offline(lastAttempt: now)
        }

        // Prior observation is preserved in connections[idx].lastObservation!
        do {
            try persistCurrentState()
        } catch {
            connections[idx].state = .persistenceFailure
        }
    }

    private func applyVerificationFailure(error: DeepSeekError, for connectionId: ConnectionID) {
        guard let idx = connections.firstIndex(where: { $0.id == connectionId }) else { return }
        switch error {
        case .authFailure(let code):
            connections[idx].state = .authFailed(statusCode: code)
        case .rateLimited(let retryAfter):
            connections[idx].state = .rateLimited(retryAfter: retryAfter)
        case .offline:
            connections[idx].state = .offline(lastAttempt: clock())
        case .timeout:
            connections[idx].state = .timeout
        case .malformedResponse, .missingRequiredField, .responseTooLarge:
            connections[idx].state = .malformedResponse
        default:
            connections[idx].state = .awaitingVerification(reason: .keyRequiresVerification)
        }
        do {
            try persistCurrentState()
        } catch {
            connections[idx].state = .persistenceFailure
        }
    }

    private func updateConnectionState(id: ConnectionID, state: ConnectionState) {
        guard let idx = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[idx].state = state
        do {
            try persistCurrentState()
        } catch {
            connections[idx].state = .persistenceFailure
        }
    }

    // MARK: - Auto-Refresh and Lifecycle (T02-R04)

    private func startAutoRefreshTimer() {
        guard schedulingActive, timerCancellable == nil else { return }
        timerCancellable = Timer.publish(every: Self.autoRefreshIntervalSeconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.refreshAll(forced: false)
                }
            }
    }

    public func pauseScheduling() {
        schedulingActive = false
        timerCancellable?.cancel()
        timerCancellable = nil
        for operation in activeOperations.values { operation.task.cancel() }
        activeOperations.removeAll()
        isRefreshing = false
        normalizeInterruptedVerification()
    }

    public func resumeScheduling() {
        schedulingActive = true
        normalizeInterruptedVerification()
        if timerCancellable == nil {
            startAutoRefreshTimer()
        }
        handleForegroundResume()
    }

    public func handleSystemWake() {
        resumeScheduling()
    }

    public func handleForegroundResume() {
        guard !isDemoMode, schedulingActive else { return }
        guard !storageManager.isBlocked else { return }
        let now = clock()
        let staleThreshold: TimeInterval = 300 // 5 minutes

        for conn in connections {
            guard isConnectionEligibleForRefresh(conn, trigger: .appResume) else {
                continue
            }

            let lastSuccess = conn.lastSuccessfulRefresh ?? .distantPast
            if now.timeIntervalSince(lastSuccess) > staleThreshold {
                Task {
                    await self.refresh(connectionId: conn.id, forced: false)
                }
            }
        }
    }

    // MARK: - Storage Recovery & Explicit Setup (Repair B, Repair C)

    public func recoverStorageByStartingFresh() throws {
        guard !isDemoMode else { throw CoordinatorError.demoModeActive }
        try storageManager.resetStorageAfterVerifiedBackup()
        loadStoredData()
    }

    public func setupImportedConnectionKey(id: ConnectionID, apiKey: String) async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CoordinatorError.missingCredential }
        guard let connection = connections.first(where: { $0.id == id }) else { throw CoordinatorError.connectionNotFound }
        try await updateConnection(id: id, userLabel: connection.userLabel, newApiKey: apiKey, monthlyBudget: connection.monthlyBudget)
    }

    // MARK: - Export and Import (T02-R01, T02-R07)

    public func exportSnapshot() throws -> Data {
        if isDemoMode {
            // Export labeled synthetic demo data in demo mode
            let demoData = StoredData(
                version: StoredData.currentVersion,
                connections: DemoFixtures.makeDemoConnections(),
                observations: DemoFixtures.makeDemoObservations(),
                pendingIntents: [],
                updatedAt: clock()
            )
            return try storageManager.exportSnapshot(data: demoData)
        }

        let currentStored = StoredData(
            version: StoredData.currentVersion,
            connections: self.connections,
            observations: self.observations,
            pendingIntents: self.pendingIntents,
            updatedAt: clock()
        )
        return try storageManager.exportSnapshot(data: currentStored)
    }

    public func importSnapshot(_ data: Data) throws {
        guard !isDemoMode else {
            throw CoordinatorError.demoModeActive
        }
        guard !storageManager.isBlocked else {
            if case .blocked(let reason) = storageManager.status {
                throw StorageError.storageBlocked(reason: reason)
            }
            throw StorageError.corruptedData
        }

        // Validate and reconstruct connections AND observations from snapshot
        let (importedConns, importedObs) = try storageManager.importSnapshot(data)

        var newConnections = self.connections
        var newObservations = self.observations

        for conn in importedConns {
            if let existingIdx = newConnections.firstIndex(where: { $0.id == conn.id }) {
                // Update existing record
                newConnections[existingIdx] = conn
            } else {
                newConnections.append(conn)
            }
        }

        for obs in importedObs {
            if !newObservations.contains(where: { $0.id == obs.id }) {
                newObservations.append(obs)
            }
        }

        let stagedData = StoredData(
            version: StoredData.currentVersion,
            connections: newConnections,
            observations: newObservations,
            pendingIntents: self.pendingIntents,
            updatedAt: clock()
        )

        // Atomic commit to storage BEFORE modifying live memory
        try storageManager.save(stagedData)

        self.connections = newConnections
        self.observations = newObservations
    }
}
