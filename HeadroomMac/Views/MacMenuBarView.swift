import SwiftUI
import HeadroomCore
#if os(macOS)
import AppKit
#endif

struct MacMenuBarView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @EnvironmentObject var subscriptions: SubscriptionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Headroom")
                    .font(.headline)

                if coordinator.isDemoMode {
                    Text("DEMO")
                        .font(.caption2.bold())
                        .foregroundColor(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(4)
                }

                Spacer()

                Button(action: {
                    Task { await subscriptions.refresh() }
                    Task { await coordinator.refreshAll(forced: true) }
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(coordinator.isRefreshing || coordinator.isDemoMode)
                .help("Refresh All Balances")
            }

            Divider()

            if !coordinator.isDemoMode && !coordinator.isFixtureMode {
                subscriptionSummary("Codex", usage: subscriptions.codex, connected: subscriptions.codexConnected)
                subscriptionSummary("Claude", usage: subscriptions.claude, connected: subscriptions.claudeConnected)
                Divider()
            }

            // Wallets list
            if coordinator.activeConnections.isEmpty {
                VStack(spacing: 6) {
                    Text("No connections configured")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Open Headroom to connect DeepSeek")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ForEach(coordinator.activeConnections) { conn in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: conn.providerId.systemImage)
                                .foregroundColor(.accentColor)
                                .font(.caption)
                            Text(conn.effectiveLabel)
                                .font(.caption.bold())
                            Spacer()
                            Text(conn.state.statusSummary)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if let obs = conn.lastObservation {
                            ForEach(obs.balances) { b in
                                HStack {
                                    Text(b.currency)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text(b.formattedTotal)
                                        .font(.caption.monospacedDigit().bold())
                                }
                            }
                            HStack {
                                Spacer()
                                Text("Updated \(obs.relativeAge)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                }
            }

            Divider()

            // App controls
            HStack {
                Button("Open Headroom") {
                    openWindow(id: "main")
                    #if os(macOS)
                    NSApp.activate(ignoringOtherApps: true)
                    #endif
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button("Quit") {
                    #if os(macOS)
                    NSApp.terminate(nil)
                    #endif
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { Task { await subscriptions.refresh() } }
    }
    private func subscriptionSummary(_ name: String, usage: SubscriptionUsage?, connected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(name).font(.caption.bold())
                Spacer()
                if usage?.windows.isEmpty != false {
                    Text(connected ? "Awaiting limits" : "Not connected").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let usage {
                ForEach(usage.windows) { window in
                    HStack {
                        Text(window.title).font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(window.remainingPercent, specifier: "%.0f")% left").font(.caption.monospacedDigit().bold())
                    }
                    ProgressView(value: window.remainingPercent, total: 100)
                    Label(QuotaPresentation.countdown(window, observedAt: usage.observedAt, now: subscriptions.displayTime), systemImage: "clock")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help(window.resetText ?? window.resetsAt?.formatted(date: .complete, time: .shortened) ?? "Reset time unavailable")
                        .padding(.bottom, 5)
                }
                if !usage.windows.isEmpty {
                    Text("\(subscriptions.freshness(usage, isClaude: name == "Claude")) · \(usage.observedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 3)
    }

}
