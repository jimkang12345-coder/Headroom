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
                    Text("Subscriptions").font(.title2.bold())
                    Text("Connect the accounts you use on this Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    .disabled(store.refreshing)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label("Codex", systemImage: "terminal.fill").font(.headline)
                                Spacer()
                                if store.refreshing && store.codexConnected { ProgressView().controlSize(.small) }
                                if store.codexConnected {
                                    Button("Disconnect") { store.disconnectCodex() }
                                } else {
                                    Button("Connect Codex") { Task { await store.connectCodex() } }.buttonStyle(.borderedProminent)
                                }
                            }
                            Text("Uses your existing Codex sign-in. Sign in to Codex with your ChatGPT subscription, then connect here.")
                                .font(.callout).foregroundStyle(.secondary)
                            if let message = store.codexMessage { Text(message).font(.callout).foregroundStyle(.orange) }
                            if let usage = store.codex { quota(usage, failed: store.codexMessage != nil) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Label("Claude", systemImage: "brain.head.profile").font(.headline)
                                Spacer()
                                if store.claudeDisconnecting {
                                    ProgressView().controlSize(.small)
                                    Text("Deleting local session…").font(.caption)
                                } else if store.claudeDisconnectFailed {
                                    Button("Retry disconnect cleanup") { Task { await store.disconnectClaude() } }
                                } else if store.claudeConnected {
                                    Button("Disconnect & delete local session") { Task { await store.disconnectClaude() } }
                                } else {
                                    Button("Connect Claude website") { Task { await store.connectClaudeWebsite() } }.buttonStyle(.borderedProminent)
                                }
                            }
                            Text("For Claude desktop and website use, connect the account usage page. Headroom reads its visible limits every 30 seconds using a separate sign-in session.")
                                .font(.callout).foregroundStyle(.secondary)
                            Text("Disconnecting deletes this app’s saved website sign-in session. This window stays on claude.ai; third-party sign-in pages and pop-up windows are currently blocked.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Open Claude website connection") { Task { await store.connectClaudeWebsite() } }
                                .disabled(store.claudeDisconnecting || store.claudeDisconnectFailed)
                            Text(store.claudeUsesWebsite ? "Source: Claude account usage page" : "Source: Claude Code status-line feed")
                                .font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Claude Code alternative") {
                                Button("Use Claude Code feed instead") { Task { await store.connectClaude() } }
                                    .disabled(store.claudeDisconnecting || store.claudeDisconnectFailed)
                                Button("Open Claude Code") { store.openClaude() }
                                    .disabled(store.connectionsPaused)
                                Text("The Code feed does not independently refresh desktop or website activity.").font(.caption)
                            }
                            Link("Open Claude usage settings", destination: URL(string: "https://claude.ai/settings/usage")!)
                            if let message = store.claudeMessage { Text(message).font(.callout).foregroundStyle(.orange) }
                            if let usage = store.claude { quota(usage, failed: store.claudeMessage != nil) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("Codex checks every 15 seconds, with slower retries on errors. Claude website checks every 30 seconds when connected. The optional Code feed is checked every 2 seconds. Provider reporting can lag. iPhone subscription syncing is not available yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
        }
        .frame(width: 680, height: 650)
        .task { await store.refresh() }
    }

    @ViewBuilder
    private func quota(_ usage: SubscriptionUsage, failed: Bool) -> some View {
        if let plan = usage.plan { Text("Plan: \(plan)").font(.caption).foregroundStyle(.secondary) }
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
                    if let reset = window.resetsAt {
                        if reset <= Date() { Text("Reset passed · awaiting update") }
                        else { Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))") }
                    } else { Text(window.resetText ?? "Reset time unavailable") }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        if !usage.windows.isEmpty {
            Text("\(failed || Date().timeIntervalSince(usage.observedAt) > 180 ? "Last known reading" : "Updated") · \(usage.observedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
