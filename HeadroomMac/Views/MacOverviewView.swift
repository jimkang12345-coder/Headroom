import SwiftUI
import HeadroomCore

struct MacOverviewView: View {
    @EnvironmentObject var subscriptions: SubscriptionStore
    @EnvironmentObject var coordinator: WalletCoordinator
    let manage: () -> Void
    let addAPI: () -> Void
    let selectWallet: (ConnectionID) -> Void
    var focusedProvider: ProviderID? = nil

    private var apiConnections: [Connection] {
        coordinator.activeConnections.filter { $0.providerId.kind != .subscription }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(pageTitle).font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("See remaining capacity and reset times for your coding subscriptions.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Manage limits", systemImage: "slider.horizontal.3", action: manage)
                        .help("Connect Codex and Claude Code limit tracking")
                }
                if coordinator.isFixtureMode || coordinator.isDemoMode {
                    Label("Synthetic preview · no live subscription readings", systemImage: "flask")
                        .font(.caption).foregroundStyle(.orange)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    if focusedProvider != .claude {
                        subscriptionCard(subscriptions.codexLabel, icon: "terminal.fill", tint: .indigo,
                                         usage: subscriptions.codex, connected: subscriptions.isSyntheticMode || subscriptions.codexConnected,
                                         message: subscriptions.codexMessage, isClaude: false,
                                         connect: { Task { await subscriptions.connectCodex() } })
                    }
                    if focusedProvider != .codex {
                        subscriptionCard(subscriptions.claudeLabel, icon: "brain.head.profile", tint: .orange,
                                         usage: subscriptions.claude, connected: subscriptions.isSyntheticMode || subscriptions.claudeConnected,
                                         message: subscriptions.claudeMessage, isClaude: true,
                                         connect: { Task { await subscriptions.connectClaude() } })
                    }
                    if focusedProvider == nil {
                        ForEach(subscriptions.extraClaude) { account in
                            extraClaudeCard(account)
                        }
                        if subscriptions.grokConnected {
                            grokCard
                        }
                        if let hermes = subscriptions.hermesLabel {
                            noteCard(hermes, icon: "antenna.radiowaves.left.and.right", text: "Signed in through T3 Code. Hermes does not publish a remaining quota, so this row stays visible without a percentage.")
                        }
                    }
                }
                Label("Provider-reported limits · unknown readings stay unknown", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                if focusedProvider == nil {
                    apiTrackers
                }
                Text("Codex checks about every 15 seconds while active; failures back off. Claude account limits refresh about once a minute. The optional Claude website source checks about every 30 seconds while active.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(focusedProvider == .claude ? "Claude Code" : focusedProvider?.displayName ?? "Limits")
    }

    private var pageTitle: String {
        switch focusedProvider {
        case .codex: "Codex limits"
        case .claude: "Claude Code limits"
        default: "Codex & Claude Code limits"
        }
    }

    private var apiTrackers: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Optional API trackers").font(.headline)
                    Text("Add API spending or balances separately from your subscription limits.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add API tracker", systemImage: "plus", action: addAPI)
                    .disabled(coordinator.isDemoMode || coordinator.isStorageBlocked)
            }
            ForEach(apiConnections) { connection in
                Button { selectWallet(connection.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: connection.providerId.systemImage)
                            .foregroundStyle(.teal).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(connection.effectiveLabel).font(.callout.weight(.medium))
                            Text(connection.state.statusSummary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let cost = connection.lastAPICostObservation {
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(cost.amount.formatted(.currency(code: cost.currency)))
                                    .font(.callout.weight(.semibold)).monospacedDigit()
                                Text("Reported API spend").font(.caption2).foregroundStyle(.secondary)
                            }
                        } else if let observation = connection.lastObservation {
                            ForEach(observation.balances) { balance in
                                Text("\(balance.formattedTotal) \(balance.currency)")
                                    .font(.callout.weight(.semibold)).monospacedDigit()
                            }
                        } else {
                            Text("View tracker").font(.caption).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }

    private func extraClaudeCard(_ account: SubscriptionStore.ExtraClaudeAccount) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile").font(.title3).foregroundStyle(.orange)
                    .frame(width: 36, height: 36)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.label).font(.title3.bold())
                    Text("Claude account limits").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let usage = account.usage, !usage.windows.isEmpty {
                ForEach(usage.windows) { window in
                    HStack {
                        Text(window.title).font(.subheadline)
                        Spacer()
                        Text("\(window.remainingPercent, specifier: "%.0f")% left").monospacedDigit()
                    }
                }
            } else {
                Text(account.connected ? (account.message ?? "Waiting for this Claude session to report limits.") : "Not connected")
                    .font(.callout).foregroundStyle(.secondary)
                if !account.connected {
                    Button("Connect T3 accounts") { Task { await subscriptions.connectDiscovered() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(subscriptions.connectionsPaused)
                }
            }
            if let message = account.message, account.usage != nil {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var grokCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Grok", systemImage: "sparkles").font(.title3.bold())
            Text("Recorded Grok session cost on this Mac. xAI does not publish remaining subscription headroom to the local client, so this is spend, not a limit percentage.")
                .font(.caption).foregroundStyle(.secondary)
            if let spend = subscriptions.grokSpend {
                Text("Today \(spend.todayUSD.formatted(.currency(code: "USD")))").font(.title3.monospacedDigit())
                Text("Last 7 days \(spend.weekUSD.formatted(.currency(code: "USD"))) · \(spend.turnCount) turns")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Reading the local session ledger…").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func noteCard(_ title: String, icon: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.title3.bold())
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func subscriptionCard(_ title: String, icon: String, tint: Color,
                                  usage: SubscriptionUsage?, connected: Bool, message: String?,
                                  isClaude: Bool, connect: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.bold())
                    Text(isClaude && subscriptions.claudeUsesWebsite ? "Claude account website source" : "Subscription limits")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if subscriptions.refreshing && !isClaude { ProgressView().controlSize(.small) }
            }
            if let usage, !usage.windows.isEmpty {
                if !usage.isComplete {
                    Label("Some limits unavailable · showing reported windows", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                ForEach(usage.windows) { window in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(window.title.replacingOccurrences(of: (isClaude ? "Claude" : title) + " · ", with: ""))
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text("\(window.remainingPercent, specifier: "%.0f")%")
                                .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text("left").font(.title3).foregroundStyle(.secondary)
                        }
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(tint.opacity(0.12))
                                Capsule().fill(window.remainingPercent <= 10 ? Color.red : tint)
                                    .frame(width: geometry.size.width * window.remainingPercent / 100)
                            }
                        }.frame(height: 7)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(title) \(window.title), \(Int(window.remainingPercent)) percent remaining")
                        HStack {
                            Text("\(window.usedPercent, specifier: "%.0f")% used")
                            Spacer()
                            Label(QuotaPresentation.countdown(window, observedAt: usage.observedAt, now: subscriptions.displayTime), systemImage: "clock")
                                .help(window.resetText ?? window.resetsAt?.formatted(date: .complete, time: .shortened) ?? "Reset time unavailable")
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if message != nil {
                    Label("Refresh failed · showing last reading", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).help(message ?? "")
                }
                Text(coordinator.isFixtureMode || coordinator.isDemoMode
                     ? "Synthetic reading"
                     : "\(subscriptions.freshness(usage, isClaude: isClaude)) · \(usage.observedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
                Button("Manage connection", action: manage).font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(connected ? "Waiting for limits" : "Connect \(title)")
                        .font(.title2.weight(.semibold))
                    Text(connectionDescription(isClaude: isClaude, connected: connected))
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !connected {
                        Button("Connect \(title)", action: connect).buttonStyle(.borderedProminent).tint(tint)
                            .disabled(subscriptions.connectionsPaused || (isClaude && (subscriptions.claudeDisconnecting || subscriptions.claudeDisconnectFailed)))
                    } else if isClaude {
                        if subscriptions.claudeUsesWebsite {
                            Button("Open website connection") { Task { await subscriptions.connectClaudeWebsite() } }
                                .disabled(subscriptions.connectionsPaused || subscriptions.claudeDisconnecting || subscriptions.claudeDisconnectFailed)
                        } else {
                            Button("Open Claude Code") { subscriptions.openClaude() }
                                .disabled(subscriptions.connectionsPaused)
                        }
                    } else {
                        Button("Retry") { Task { await subscriptions.refresh() } }
                            .disabled(subscriptions.connectionsPaused || subscriptions.refreshing)
                    }
                    if let message {
                        Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Manage connection", action: manage).font(.caption)
                }.frame(minHeight: 150, alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 295, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(tint.opacity(0.18)))
    }

    private func connectionDescription(isClaude: Bool, connected: Bool) -> String {
        if isClaude {
            if connected && subscriptions.claudeUsesWebsite {
                return "Sign in to the optional Claude website source for its reported account limits."
            }
            return connected
                ? "Open a signed-in Claude Code session. Limits arrive through its local status-line feed."
                : "Use your Claude Code subscription and a local status-line feed. No API key is needed."
        }
        return connected
            ? "Your usage will appear here after the local Codex client responds."
            : "Use your existing ChatGPT sign-in in Codex. No API key is needed."
    }
}
