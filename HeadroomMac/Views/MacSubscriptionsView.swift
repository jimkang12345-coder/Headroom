import SwiftUI
import AppKit
import HeadroomCore

struct MacSubscriptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: SubscriptionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex & Claude Code limits").font(.title2.bold())
                    Text("Connect the coding subscriptions you use on this Mac, including every Claude account enabled in T3 Code.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    .disabled(store.refreshing || store.connectionsPaused)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if store.connectionsPaused {
                        Label("Synthetic preview · connection actions are paused", systemImage: "flask")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Button("Connect T3 Code accounts") { Task { await store.connectDiscovered() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.connectionsPaused || store.claudeDisconnecting)
                    Text("Connects Codex, reads limits for each enabled T3 Claude account, and shows Grok’s local session cost. Hermes stays listed because it publishes no quota.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(store.extraClaude) { account in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(account.label, systemImage: "brain.head.profile").font(.headline)
                                if account.usage?.windows.isEmpty != false {
                                    Text(account.connected ? (account.message ?? "Reading this Claude account’s limits…") : "Not connected")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                if let usage = account.usage, !usage.windows.isEmpty {
                                    quota(usage, isClaude: true, failed: account.message != nil)
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label(store.codexLabel, systemImage: "terminal.fill").font(.headline)
                                Spacer()
                                if store.refreshing && store.codexConnected { ProgressView().controlSize(.small) }
                                if store.codexConnected {
                                    Button("Disconnect") { store.disconnectCodex() }
                                        .disabled(store.connectionsPaused)
                                } else {
                                    Button("Connect Codex") { Task { await store.connectCodex() } }.buttonStyle(.borderedProminent)
                                        .disabled(store.connectionsPaused)
                                }
                            }
                            Text("Uses your existing Codex sign-in with a ChatGPT subscription. Headroom reads limits through the local official Codex client; an API key is not needed.")
                                .font(.callout).foregroundStyle(.secondary)
                            if let message = store.codexMessage { Text(message).font(.callout).foregroundStyle(.orange) }
                            if let usage = store.codex { quota(usage, isClaude: false, failed: store.codexMessage != nil) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label(store.claudeLabel, systemImage: "brain.head.profile").font(.headline)
                                Spacer()
                                if store.claudeDisconnecting {
                                    ProgressView().controlSize(.small)
                                    Text("Cleaning up local connection…").font(.caption)
                                } else if store.claudeDisconnectFailed {
                                    Button("Retry disconnect cleanup") { Task { await store.disconnectClaude() } }
                                        .disabled(store.connectionsPaused)
                                } else if store.claudeConnected {
                                    Button(store.claudeUsesWebsite ? "Disconnect & delete local sign-in" : "Disconnect local feed") { Task { await store.disconnectClaude() } }
                                        .disabled(store.connectionsPaused)
                                } else {
                                    Button("Connect Claude Code") { Task { await store.connectClaude() } }.buttonStyle(.borderedProminent)
                                        .disabled(store.connectionsPaused)
                                }
                            }
                            Text("Uses your signed-in Claude Code subscription. Headroom reads the 5-hour and weekly limits for that account. The local status line is kept when Claude Code reports one.")
                                .font(.callout).foregroundStyle(.secondary)
                            if store.claudeConnected && !store.claudeUsesWebsite {
                                Button("Open Claude Code") { store.openClaude() }
                                    .disabled(store.connectionsPaused)
                            } else if store.claudeUsesWebsite {
                                Text("Your current website source is retained. Switch to the Code feed when you choose.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Switch to Claude Code feed") { Task { await store.connectClaude() } }
                                    .disabled(claudeActionsDisabled)
                            }
                            Text("Source: \(claudeSourceDescription)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Account limits refresh about once a minute from the signed-in Claude Code account. The status line is still recorded when Claude Code emits it. Context usage is separate.")
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Optional Claude website source") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Read the account usage page using a separate sign-in session. The provider reports account-wide limits; this is an alternative to the Code feed.")
                                        .font(.callout).foregroundStyle(.secondary)
                                    Button(store.claudeUsesWebsite ? "Open website connection" : "Use Claude website instead") { Task { await store.connectClaudeWebsite() } }
                                        .disabled(claudeActionsDisabled)
                                    Text("Switching from the website removes Headroom’s saved sign-in session. Disconnect also deletes it; cleanup failures must be retried. Main navigation stays on claude.ai, and external sign-in pages and pop-ups are currently blocked.")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Link("Claude usage settings", destination: URL(string: "https://claude.ai/settings/usage")!)
                                        .disabled(store.connectionsPaused)
                                }.padding(.top, 8)
                            }
                            if let message = store.claudeMessage { Text(message).font(.callout).foregroundStyle(.orange) }
                            if let usage = store.claude { quota(usage, isClaude: true, failed: store.claudeMessage != nil) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Codex checks every 15 seconds, with slower retries on errors. Claude account limits refresh about once a minute. Provider reporting can lag. API budgets are separate optional trackers.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
        }
        .frame(width: 720, height: 700)
        .task { await store.refresh() }
    }

    private var claudeSourceDescription: String {
        if store.isSyntheticMode { return "Synthetic sample" }
        guard store.claudeConnected else { return "Not connected" }
        if store.claudeUsesWebsite { return "Claude account usage page" }
        return store.claudeAccountLimits ? "Claude account limits" : "Claude Code status-line feed"
    }

    private var claudeActionsDisabled: Bool {
        store.connectionsPaused || store.claudeDisconnecting || store.claudeDisconnectFailed
    }

    @ViewBuilder
    private func quota(_ usage: SubscriptionUsage, isClaude: Bool, failed: Bool) -> some View {
        if let plan = usage.plan { Text("Plan: \(plan)").font(.caption).foregroundStyle(.secondary) }
        if !usage.isComplete, !usage.windows.isEmpty {
            Label("Some limits unavailable · showing reported windows", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.orange)
        }
        ForEach(usage.windows) { window in
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(window.title).font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(window.remainingPercent, specifier: "%.0f")% remaining").monospacedDigit()
                }
                ProgressView(value: window.usedPercent, total: 100)
                    .tint(window.usedPercent >= 90 ? .orange : .accentColor)
                    .accessibilityLabel("\(window.title), \(Int(window.usedPercent)) percent used")
                HStack {
                    Text("\(window.usedPercent, specifier: "%.0f")% used")
                    Spacer()
                    Text(QuotaPresentation.countdown(window, observedAt: usage.observedAt, now: store.displayTime))
                        .help(window.resetText ?? window.resetsAt?.formatted(date: .complete, time: .shortened) ?? "Reset time unavailable")
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        if !usage.windows.isEmpty {
            Text(store.isSyntheticMode ? "Synthetic reading" : "\(failed ? "Last known reading" : store.freshness(usage, isClaude: isClaude)) · \(usage.observedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
