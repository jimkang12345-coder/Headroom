import SwiftUI
import HeadroomCore
#if os(macOS)
import AppKit
#endif

struct MacMenuBarView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @EnvironmentObject var subscriptions: SubscriptionStore
    @Environment(\.openWindow) private var openWindow
    @State private var showsAPITrackers = false

    private var apiConnections: [Connection] {
        coordinator.activeConnections.filter { $0.providerId.kind != .subscription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Headroom").font(.headline)
                    Text("Codex & Claude Code limits").font(.caption2).foregroundStyle(.secondary)
                }
                if coordinator.isFixtureMode || coordinator.isDemoMode {
                    Text("SAMPLE").font(.caption2.bold()).foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
                Spacer()
                Button(action: {
                    Task { await subscriptions.refresh() }
                    Task { await coordinator.refreshAll(forced: true) }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isRefreshing || subscriptions.refreshing || coordinator.isDemoMode)
                .help("Refresh limits and added API trackers")
            }

            subscriptionSummary("Codex", usage: subscriptions.codex,
                                connected: subscriptions.isSyntheticMode || subscriptions.codexConnected, isClaude: false)
            subscriptionSummary("Claude Code", usage: subscriptions.claude,
                                connected: subscriptions.isSyntheticMode || subscriptions.claudeConnected, isClaude: true)

            Divider()
            DisclosureGroup("Optional API trackers\(apiConnections.isEmpty ? "" : " (\(apiConnections.count))")", isExpanded: $showsAPITrackers) {
                VStack(alignment: .leading, spacing: 8) {
                    if apiConnections.isEmpty {
                        Text("Add spending or balances from the main window when you need them.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        ForEach(apiConnections) { connection in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: connection.providerId.systemImage).foregroundStyle(.teal)
                                    Text(connection.effectiveLabel).font(.caption.bold())
                                    Spacer()
                                    Text(connection.state.statusSummary).font(.caption2).foregroundStyle(.secondary)
                                }
                                if let cost = connection.lastAPICostObservation {
                                    HStack {
                                        Text("Reported API spend").font(.caption2).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(cost.amount.formatted(.currency(code: cost.currency))).font(.caption.monospacedDigit().bold())
                                    }
                                } else if let observation = connection.lastObservation {
                                    ForEach(observation.balances) { balance in
                                        HStack {
                                            Text(balance.currency).font(.caption2).foregroundStyle(.secondary)
                                            Spacer()
                                            Text(balance.formattedTotal).font(.caption.monospacedDigit().bold())
                                        }
                                    }
                                }
                            }
                            .padding(8)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    Button("Manage API trackers in Headroom", action: showMainWindow)
                        .font(.caption)
                }.padding(.top, 8)
            }.font(.caption)

            Divider()
            HStack {
                Button("Open limits", action: showMainWindow)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Spacer()
                Button("Quit") {
                    #if os(macOS)
                    NSApp.terminate(nil)
                    #endif
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 310)
        .onAppear { Task { await subscriptions.refresh() } }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }

    private func subscriptionSummary(_ name: String, usage: SubscriptionUsage?, connected: Bool, isClaude: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(name, systemImage: isClaude ? "brain.head.profile" : "terminal.fill")
                    .font(.callout.weight(.semibold))
                Spacer()
                if usage?.windows.isEmpty != false {
                    Text(connected ? "Awaiting limits" : "Not connected").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let usage, !usage.windows.isEmpty {
                if !usage.isComplete {
                    Label("Some limits unavailable", systemImage: "questionmark.circle")
                        .font(.caption2).foregroundStyle(.orange)
                }
                ForEach(usage.windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(window.title.replacingOccurrences(of: (isClaude ? "Claude" : name) + " · ", with: "")).font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(window.remainingPercent, specifier: "%.0f")% left").font(.caption.monospacedDigit().bold())
                        }
                        ProgressView(value: window.remainingPercent, total: 100)
                            .tint(isClaude ? .orange : .indigo)
                        Label(QuotaPresentation.countdown(window, observedAt: usage.observedAt, now: subscriptions.displayTime), systemImage: "clock")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help(window.resetText ?? window.resetsAt?.formatted(date: .complete, time: .shortened) ?? "Reset time unavailable")
                    }
                }
                Text(subscriptions.isSyntheticMode
                     ? "Synthetic reading"
                     : "\(subscriptions.freshness(usage, isClaude: isClaude)) · \(usage.observedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if !connected {
                Button("Connect in Headroom", action: showMainWindow)
                    .font(.caption).buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}
