import SwiftUI
import HeadroomCore

struct IOSContentView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @State private var selectedTab: Int = 0
    @State private var showDetailConnectionID: ConnectionID?

    init() {
        #if DEBUG
        if let idx = CommandLine.arguments.firstIndex(of: "-selectedTab"),
           idx + 1 < CommandLine.arguments.count,
           let val = Int(CommandLine.arguments[idx + 1]) {
            _selectedTab = State(initialValue: val)
        }
        if CommandLine.arguments.contains("-showDetail") {
            _showDetailConnectionID = State(initialValue: DemoFixtures.deepSeekConnectionID)
        }
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            IOSOverviewTab(detailPushID: $showDetailConnectionID)
                .tabItem {
                    Label("Overview", systemImage: "gauge.with.dots.needle.bottom.50percent")
                }
                .tag(0)

            IOSConnectionsTab()
                .tabItem {
                    Label("Connections", systemImage: "link")
                }
                .tag(1)

            IOSSettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
    }
}

struct IOSOverviewTab: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @Binding var detailPushID: ConnectionID?
    @State private var isShowingSetupSheet: Bool = false

    init(detailPushID: Binding<ConnectionID?> = .constant(nil)) {
        self._detailPushID = detailPushID
        #if DEBUG
        if CommandLine.arguments.contains("-showSetupSheet") {
            _isShowingSetupSheet = State(initialValue: true)
        }
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    IOSRecoveryNotice()

                    if coordinator.isFixtureMode {
                        fixtureBanner
                    }

                    if coordinator.isDemoMode {
                        demoBanner
                    }

                    if coordinator.activeConnections.isEmpty && !coordinator.isDemoMode {
                        firstLaunchCard
                    } else {
                        walletsSection
                        subscriptionsSection
                    }
                }
                .padding(16)
            }
            .navigationTitle("Headroom")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !coordinator.isDemoMode {
                        Button(action: {
                            Task { await coordinator.refreshAll(forced: true) }
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(coordinator.isRefreshing)
                        .accessibilityLabel("Refresh All Balances")
                    }

                    Button(action: { isShowingSetupSheet = true }) {
                        Image(systemName: "plus")
                    }
                    .disabled(coordinator.isDemoMode || coordinator.isStorageBlocked)
                    .accessibilityLabel("Add Provider Connection")
                }
            }
            .sheet(isPresented: $isShowingSetupSheet) {
                IOSConnectionSetupView()
                    .environmentObject(coordinator)
            }
            .navigationDestination(item: $detailPushID) { id in
                IOSWalletDetailView(connectionId: id)
                    .environmentObject(coordinator)
            }
        }
    }

    @ViewBuilder
    private var demoBanner: some View {
        HStack {
            Image(systemName: "flask.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("DEMO MODE ACTIVE")
                    .font(.caption.bold())
                    .foregroundColor(.orange)
                Text("Showing synthetic balances. No real network calls.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Exit") {
                coordinator.setDemoMode(false)
            }
            .font(.caption.bold())
            .buttonStyle(.bordered)
            .accessibilityLabel("Exit Demo Mode")
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var fixtureBanner: some View {
        HStack {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundColor(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("FIXTURE MODE (ISOLATED)")
                    .font(.caption.bold())
                    .foregroundColor(.purple)
                Text("Using isolated test storage and synthetic Keychain.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.purple.opacity(0.12))
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var firstLaunchCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "creditcard.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 6) {
                Text("Track AI Developer Wallets")
                    .font(.title3.bold())
                Text("See your latest saved AI wallet balances. Connect DeepSeek to get started.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 10) {
                Button(action: { isShowingSetupSheet = true }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Connect DeepSeek")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(coordinator.isStorageBlocked)

                Button(action: { coordinator.setDemoMode(true) }) {
                    HStack {
                        Image(systemName: "flask")
                        Text("Explore Demo Mode")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(20)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    @ViewBuilder
    private var walletsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Wallets")
                .font(.headline)

            ForEach(coordinator.activeConnections.filter { $0.providerId.kind == .wallet }) { conn in
                NavigationLink(destination: IOSWalletDetailView(connectionId: conn.id).environmentObject(coordinator)) {
                    IOSWalletCard(connection: conn)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var subscriptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Subscriptions")
                .font(.headline)

            HStack(spacing: 14) {
                Image(systemName: "terminal.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex / Claude / AGY")
                        .font(.body.weight(.medium))
                    Text("Subscription quota monitoring coming soon")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("Upcoming")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
            }
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Subscriptions: Codex, Claude, Antigravity. Quota monitoring coming soon.")
        }
    }
}

struct IOSWalletCard: View {
    let connection: Connection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var adaptiveRow: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            adaptiveRow {
                Image(systemName: connection.providerId.systemImage)
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)
                Text(connection.effectiveLabel)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                if !dynamicTypeSize.isAccessibilitySize { Spacer() }

                connectionStateBadge
            }

            if let observation = connection.lastObservation {
                VStack(spacing: 8) {
                    ForEach(observation.balances) { b in
                        adaptiveRow {
                            Text(b.currency)
                                .font(.caption.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(4)
                                .fixedSize()

                            Text(b.formattedTotal)
                                .font(.title3.monospacedDigit().bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.45)
                                .allowsTightening(true)
                                .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                        }
                    }
                }

                adaptiveRow {
                    if let lastSuccess = connection.lastSuccessfulRefresh {
                        Text("Updated \(lastSuccess, style: .relative) ago")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Text(observation.isAvailable ? "Sufficient" : "Depleted")
                        .font(.caption2.bold())
                        .foregroundColor(observation.isAvailable ? .green : .red)
                }
            } else {
                Text(connection.state.statusSummary)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibleCardLabel)
    }

    private var accessibleCardLabel: String {
        var label = "\(connection.effectiveLabel), \(connection.providerId.displayName), Status: \(connection.state.statusSummary)"
        if let obs = connection.lastObservation {
            for b in obs.balances {
                label += ", \(b.currency): \(b.formattedTotal)"
            }
            if let lastSuccess = connection.lastSuccessfulRefresh {
                let relative = RelativeDateTimeFormatter().localizedString(for: lastSuccess, relativeTo: Date())
                label += ", Updated \(relative)"
            }
            label += ", Sufficiency: \(obs.isAvailable ? "Sufficient" : "Depleted")"
        }
        return label
    }

    @ViewBuilder
    private var connectionStateBadge: some View {
        HStack(spacing: 4) {
            switch connection.state {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption2)
                Text("Ready")
                    .font(.caption2.bold())
                    .foregroundColor(.green)
            case .verifying:
                ProgressView().controlSize(.mini)
            case .rateLimited:
                Image(systemName: "hourglass")
                    .foregroundColor(.orange)
                    .font(.caption2)
                Text("Rate Limited")
                    .font(.caption2.bold())
                    .foregroundColor(.orange)
            case .authFailed:
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.red)
                    .font(.caption2)
                Text("Auth Error")
                    .font(.caption2.bold())
                    .foregroundColor(.red)
            case .offline:
                Image(systemName: "wifi.slash")
                    .foregroundColor(.gray)
                    .font(.caption2)
                Text("Offline")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            default:
                Text(connection.state.statusSummary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct IOSConnectionsTab: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @State private var isShowingSetupSheet: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if coordinator.showsRecoveryNotice {
                    Section { IOSRecoveryNotice() }
                }
                Section("Configured Connections") {
                    if coordinator.activeConnections.isEmpty {
                        Text("No connections configured.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(coordinator.activeConnections) { conn in
                            NavigationLink(destination: IOSWalletDetailView(connectionId: conn.id).environmentObject(coordinator)) {
                                HStack {
                                    Image(systemName: conn.providerId.systemImage)
                                        .foregroundColor(.accentColor)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(conn.effectiveLabel)
                                            .font(.body.weight(.medium))
                                        Text(conn.providerId.displayName)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(conn.state.statusSummary)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                Section("Supported Providers") {
                    ForEach(ProviderID.allCases) { provider in
                        HStack {
                            Image(systemName: provider.systemImage)
                                .foregroundColor(provider.isImplemented ? .accentColor : .secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                    .font(.body)
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
                    }
                }
            }
            .navigationTitle("Connections")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { isShowingSetupSheet = true }) {
                        Image(systemName: "plus")
                    }
                    .disabled(coordinator.isDemoMode || coordinator.isStorageBlocked)
                    .accessibilityLabel("Add Provider Connection")
                }
            }
            .sheet(isPresented: $isShowingSetupSheet) {
                IOSConnectionSetupView()
                    .environmentObject(coordinator)
            }
        }
    }
}

// Each screen places this notice inside its own scrolling content so large text
// never competes with navigation bars or the tab bar for a fixed safe-area inset.
extension WalletCoordinator {
    var showsRecoveryNotice: Bool {
        !isDemoMode && (isStorageBlocked || !pendingIntents.isEmpty || lastErrorMessage != nil)
    }
}

struct IOSRecoveryNotice: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if coordinator.showsRecoveryNotice {
            VStack(alignment: .leading, spacing: 10) {
                if coordinator.isStorageBlocked {
                    Label("Storage Recovery Required", systemImage: "exclamationmark.octagon.fill")
                        .font(.headline)
                    Text("Saved data could not be opened. Changes are paused to protect existing files.")
                        .font(.caption)
                    Text(coordinator.lastErrorMessage ?? coordinator.storageStatus.description)
                        .font(.caption)
                        .accessibilityIdentifier("global-recovery-error")
                    recoveryActions
                } else {
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
                        .accessibilityIdentifier("retry-connection-recovery")
                    }
                    if let error = coordinator.lastErrorMessage {
                        Text(error).font(.caption).accessibilityIdentifier("global-recovery-error")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background((coordinator.isStorageBlocked ? Color.red : Color.orange).opacity(0.12))
            .cornerRadius(12)
            .accessibilityElement(children: .contain)
        }
    }

    private var recoveryActions: some View {
        (dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))) {
            Button("Retry Load") { coordinator.loadStoredData() }
                .buttonStyle(.borderedProminent)
            Button("Start Fresh (Preserve Backup)") {
                do { try coordinator.recoverStorageByStartingFresh() }
                catch { coordinator.lastErrorMessage = error.localizedDescription }
            }
            .buttonStyle(.bordered)
        }
    }
}
