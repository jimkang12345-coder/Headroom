import SwiftUI
import HeadroomCore

struct MacContentView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @EnvironmentObject var subscriptions: SubscriptionStore
    private static let overviewID = ConnectionID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let codexID = ConnectionID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private static let claudeID = ConnectionID(uuidString: "00000000-0000-0000-0000-000000000003")!
    @State private var selectedConnectionID: ConnectionID? = overviewID
    @State private var isShowingSetupSheet: Bool = false
    @State private var isShowingSettingsSheet: Bool = false
    @State private var isShowingSubscriptions = false

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
        } detail: {
            detailContent
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            MacRecoveryNotice().environmentObject(coordinator)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if coordinator.isFixtureMode {
                    HStack(spacing: 4) {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundColor(.purple)
                        Text("FIXTURE MODE")
                            .font(.caption.bold())
                            .foregroundColor(.purple)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.15))
                    .cornerRadius(6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Fixture Mode Active")
                }

                if coordinator.isDemoMode {
                    HStack(spacing: 4) {
                        Image(systemName: "flask.fill")
                            .foregroundColor(.orange)
                        Text("DEMO MODE")
                            .font(.caption.bold())
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Demo Mode Active")

                    Button("Exit Demo") {
                        coordinator.setDemoMode(false)
                    }
                    .accessibilityHint("Restores your real local connections and balances")
                } else {
                    Button(action: { coordinator.setDemoMode(true) }) {
                        Label("Demo Mode", systemImage: "flask")
                    }
                    .help("Preview multi-currency synthetic wallets in safe isolated demo mode")
                    .accessibilityLabel("Enter Demo Mode")
                }

                Button(action: {
                    Task { await subscriptions.refresh() }
                    Task { await coordinator.refreshAll(forced: true) }
                }) {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isRefreshing || coordinator.isDemoMode)
                .help("Refresh balances from active providers")
                .accessibilityLabel("Refresh All Balances")

                Button(action: { isShowingSetupSheet = true }) {
                    Label("Add Connection", systemImage: "plus")
                }
                .disabled(coordinator.isDemoMode || coordinator.isStorageBlocked)
                .help(coordinator.isDemoMode ? "Exit Demo Mode to add real accounts" : "Add new provider connection")
                .accessibilityLabel("Add Provider Connection")

                Button(action: { isShowingSettingsSheet = true }) {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open settings")
                .accessibilityLabel("Open Settings")
            }
        }
        .sheet(isPresented: $isShowingSetupSheet) {
            MacConnectionSetupView()
                .environmentObject(coordinator)
                .environmentObject(subscriptions)
        }
        .sheet(isPresented: $isShowingSubscriptions) {
            MacSubscriptionsView().environmentObject(subscriptions)
        }
        .sheet(isPresented: $isShowingSettingsSheet) {
            MacSettingsView()
                .environmentObject(coordinator)
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        List(selection: $selectedConnectionID) {
            Section {
                NavigationLink(value: Self.overviewID) {
                    Label("Overview", systemImage: "square.grid.2x2.fill")
                        .fontWeight(selectedConnectionID == Self.overviewID ? .semibold : .regular)
                }
            }
            if !coordinator.isDemoMode && !coordinator.isFixtureMode {
                Section("Subscriptions") {
                    NavigationLink(value: Self.codexID) {
                        subscriptionRow("Codex", icon: "terminal.fill", usage: subscriptions.codex, connected: subscriptions.codexConnected)
                    }
                    NavigationLink(value: Self.claudeID) {
                        subscriptionRow("Claude", icon: "brain.head.profile", usage: subscriptions.claude, connected: subscriptions.claudeConnected)
                    }
                    Button("Manage connections") { isShowingSubscriptions = true }
                        .font(.caption)
                }
            }
            if coordinator.isStorageBlocked {
                storageBlockedSection
            }

            if coordinator.activeConnections.isEmpty && !coordinator.isDemoMode {
                firstLaunchSection
            } else {
                Section("API Wallets") {
                    ForEach(coordinator.activeConnections.filter { $0.providerId.kind == .wallet }) { conn in
                        NavigationLink(value: conn.id) {
                            ConnectionSidebarRow(connection: conn)
                        }
                    }
                }

                Section("Provider Catalog") {
                    ForEach(ProviderID.allCases.filter { $0 != .codex && $0 != .claude }) { provider in
                        HStack {
                            Image(systemName: provider.systemImage)
                                .foregroundColor(provider.isImplemented ? .accentColor : .secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                    .font(.callout)
                                Text(provider.statusDescription)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if provider.isImplemented {
                                Text("Ready")
                                    .font(.caption2.bold())
                                    .foregroundColor(.green)
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(provider.displayName): \(provider.statusDescription)")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .buttonStyle(.plain)
    }

    private func subscriptionRow(_ title: String, icon: String, usage: SubscriptionUsage?, connected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let window = usage?.windows.max(by: { $0.usedPercent < $1.usedPercent }) {
                    Text("\(window.remainingPercent, specifier: "%.0f")% left · \(window.title)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(connected ? "Awaiting limits" : "Not connected").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 3)
    }

    @ViewBuilder
    private var firstLaunchSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Headroom")
                    .font(.headline)
                Text("Track your AI subscriptions and wallet balances. Open Codex & Claude above, or connect DeepSeek below.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 8) {
                Button(action: { isShowingSetupSheet = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Connect DeepSeek")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button(action: { coordinator.setDemoMode(true) }) {
                    HStack {
                        Image(systemName: "flask")
                        Text("Preview Demo Mode")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.top, 4)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("Local storage only", systemImage: "lock.shield")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Label("Direct provider API requests", systemImage: "network")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Label("No intermediate server", systemImage: "server.rack")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var detailContent: some View {
        if coordinator.isStorageBlocked && coordinator.activeConnections.isEmpty {
            storageBlockedDetailPane
        } else if !coordinator.activeConnections.contains(where: { $0.id == selectedConnectionID }) && !coordinator.isDemoMode && !coordinator.isFixtureMode {
            MacOverviewView(manage: { isShowingSubscriptions = true }, selectWallet: { selectedConnectionID = $0 })
                .environmentObject(subscriptions)
                .environmentObject(coordinator)
        } else if let selectedID = selectedConnectionID ?? coordinator.activeConnections.first?.id,
           let connection = coordinator.activeConnections.first(where: { $0.id == selectedID }) {
            MacWalletDetailView(connectionId: connection.id)
                .environmentObject(coordinator)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "creditcard")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("Select a Wallet")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("Choose a connection from the sidebar or click '+' to connect a new provider.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var storageBlockedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundColor(.red)
                Text("Storage Blocked")
                    .font(.subheadline.bold())
                    .foregroundColor(.red)
            }
            Text("Saved data could not be opened. Writes are locked to protect existing files.")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button("Retry Load") {
                    coordinator.loadStoredData()
                }
                .controlSize(.small)

                Button("Start Fresh") {
                    do {
                        try coordinator.recoverStorageByStartingFresh()
                    } catch {
                        coordinator.lastErrorMessage = error.localizedDescription
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var storageBlockedDetailPane: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("Storage Write-Locked")
                .font(.title2.bold())
            Text("Headroom detected an unreadable or future storage schema:\n\(coordinator.storageStatus.description)")
                .multilineTextAlignment(.center)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(maxWidth: 450)
            Text("To prevent data corruption, all writes are blocked until explicit recovery.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                Button("Retry Load") {
                    coordinator.loadStoredData()
                }
                .buttonStyle(.borderedProminent)

                Button("Start Fresh (Preserve Backup)") {
                    do {
                        try coordinator.recoverStorageByStartingFresh()
                    } catch {
                        coordinator.lastErrorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct ConnectionSidebarRow: View {
    let connection: Connection

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: connection.providerId.systemImage)
                .foregroundColor(.accentColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text(connection.effectiveLabel)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if let observation = connection.lastObservation, let primary = observation.primaryBalance {
                    Text("\(primary.formattedTotal) (\(primary.currency))")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.primary)
                }

                // Visible non-color status indication
                HStack(spacing: 4) {
                    statusIcon
                    Text(connection.state.statusSummary)
                        .font(.caption2)
                        .foregroundColor(statusTextColor)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibleRowLabel)
    }

    private var accessibleRowLabel: String {
        var parts: [String] = [connection.effectiveLabel, connection.providerId.displayName]
        if let obs = connection.lastObservation, let primary = obs.primaryBalance {
            parts.append("Balance: \(primary.formattedTotal) \(primary.currency)")
        }
        parts.append("Status: \(connection.state.statusSummary)")
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch connection.state {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.caption2)
        case .verifying:
            ProgressView()
                .controlSize(.mini)
        case .rateLimited:
            Image(systemName: "hourglass")
                .foregroundColor(.orange)
                .font(.caption2)
        case .authFailed:
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundColor(.red)
                .font(.caption2)
        case .offline:
            Image(systemName: "wifi.slash")
                .foregroundColor(.gray)
                .font(.caption2)
        case .timeout:
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundColor(.orange)
                .font(.caption2)
        case .malformedResponse, .serverError:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.caption2)
        case .keychainFailure, .persistenceFailure:
            Image(systemName: "externaldrive.badge.xmark")
                .foregroundColor(.red)
                .font(.caption2)
        case .awaitingVerification:
            Image(systemName: "questionmark.circle.fill")
                .foregroundColor(.orange)
                .font(.caption2)
        default:
            Image(systemName: "circle.fill")
                .foregroundColor(.secondary)
                .font(.caption2)
        }
    }

    private var statusTextColor: Color {
        switch connection.state {
        case .ready:
            return .secondary
        case .rateLimited:
            return .orange
        case .authFailed, .malformedResponse, .serverError, .keychainFailure, .persistenceFailure:
            return .red
        case .offline, .timeout:
            return .secondary
        case .awaitingVerification:
            return .orange
        default:
            return .secondary
        }
    }
}

private struct MacRecoveryNotice: View {
    @EnvironmentObject var coordinator: WalletCoordinator

    var body: some View {
        if !coordinator.isDemoMode && (!coordinator.pendingIntents.isEmpty || coordinator.lastErrorMessage != nil) {
            VStack(alignment: .leading, spacing: 6) {
                if !coordinator.pendingIntents.isEmpty {
                    Label("Connection Recovery Required", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                    Text("A credential change or removal needs cleanup. Balance requests for affected connections are paused.")
                        .font(.caption)
                    Button("Retry Recovery") {
                        do { try coordinator.retryRecovery() }
                        catch { coordinator.lastErrorMessage = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(coordinator.isStorageBlocked)
                    .accessibilityIdentifier("retry-connection-recovery")
                }
                if let error = coordinator.lastErrorMessage {
                    Text(error).font(.caption).accessibilityIdentifier("global-recovery-error")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.orange.opacity(0.15))
            .accessibilityElement(children: .contain)
        }
    }
}
