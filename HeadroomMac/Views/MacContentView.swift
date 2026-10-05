import SwiftUI
import HeadroomCore

struct MacContentView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @EnvironmentObject var subscriptions: SubscriptionStore
    private static let overviewID = ConnectionID(uuidString: "00000000-0000-0000-0000-00000000F001")!
    private static let codexID = ConnectionID(uuidString: "00000000-0000-0000-0000-00000000F002")!
    private static let claudeID = ConnectionID(uuidString: "00000000-0000-0000-0000-00000000F003")!
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
                    .help("Preview synthetic limits and API readings")
                    .accessibilityLabel("Enter Demo Mode")
                }

                Button(action: {
                    Task { await subscriptions.refresh() }
                    Task { await coordinator.refreshAll(forced: true) }
                }) {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isRefreshing || subscriptions.refreshing || coordinator.isDemoMode)
                .help("Refresh subscription limits and added API trackers")
                .accessibilityLabel("Refresh Limits and API Trackers")

                Button(action: { isShowingSubscriptions = true }) {
                    Label("Manage Limits", systemImage: "slider.horizontal.3")
                }
                .help("Connect Codex and Claude Code subscription tracking")

                Button(action: { isShowingSetupSheet = true }) {
                    Label("Add API Tracker", systemImage: "plus")
                }
                .disabled(coordinator.isDemoMode || coordinator.isStorageBlocked)
                .help(coordinator.isDemoMode ? "Exit Demo Mode to add real accounts" : "Add an optional API budget or balance tracker")
                .accessibilityLabel("Add API Tracker")

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
            Section("Subscription limits") {
                NavigationLink(value: Self.overviewID) {
                    Label("All limits", systemImage: "gauge.with.needle.fill")
                        .fontWeight(selectedConnectionID == Self.overviewID ? .semibold : .regular)
                }
                NavigationLink(value: Self.codexID) {
                    subscriptionRow("Codex", icon: "terminal.fill", usage: subscriptions.codex, connected: subscriptions.isSyntheticMode || subscriptions.codexConnected)
                }
                NavigationLink(value: Self.claudeID) {
                    subscriptionRow("Claude Code", icon: "brain.head.profile", usage: subscriptions.claude, connected: subscriptions.isSyntheticMode || subscriptions.claudeConnected)
                }
                Button("Manage limit connections") { isShowingSubscriptions = true }
                    .font(.caption)
            }

            Section("Optional API trackers") {
                ForEach(coordinator.activeConnections.filter { $0.providerId.kind != .subscription }) { connection in
                    NavigationLink(value: connection.id) {
                        ConnectionSidebarRow(connection: connection)
                    }
                }
                Button(action: { isShowingSetupSheet = true }) {
                    Label("Add API tracker", systemImage: "plus.circle")
                }
                .disabled(coordinator.isDemoMode || coordinator.isStorageBlocked)
                if coordinator.activeConnections.isEmpty {
                    Text("Add budgets or balances when you need them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if coordinator.isStorageBlocked {
                storageBlockedSection
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
                if let usage, !usage.isComplete, !usage.windows.isEmpty {
                    Text("Partial reading · some limits unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let window = usage?.windows.max(by: { $0.usedPercent < $1.usedPercent }) {
                    Text("\(window.remainingPercent, specifier: "%.0f")% left · \(window.title)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(connected ? "Awaiting limits" : "Not connected").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 3)
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedID = selectedConnectionID,
           ![Self.overviewID, Self.codexID, Self.claudeID].contains(selectedID),
           let connection = coordinator.activeConnections.first(where: { $0.id == selectedID }) {
            MacWalletDetailView(connectionId: connection.id)
                .environmentObject(coordinator)
        } else {
            MacOverviewView(
                manage: { isShowingSubscriptions = true },
                addAPI: { isShowingSetupSheet = true },
                selectWallet: { selectedConnectionID = $0 },
                focusedProvider: selectedConnectionID == Self.codexID ? .codex : selectedConnectionID == Self.claudeID ? .claude : nil
            )
            .environmentObject(subscriptions)
            .environmentObject(coordinator)
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

                if let cost = connection.lastAPICostObservation {
                    Text("\(cost.amount.formatted(.currency(code: cost.currency))) API spend")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.primary)
                } else if let observation = connection.lastObservation, let primary = observation.primaryBalance {
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
        if let cost = connection.lastAPICostObservation {
            parts.append("API spend: \(cost.amount.formatted(.currency(code: cost.currency)))")
        } else if let obs = connection.lastObservation, let primary = obs.primaryBalance {
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
