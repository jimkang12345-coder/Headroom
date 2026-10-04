import SwiftUI
import HeadroomCore

struct MacOverviewView: View {
    @EnvironmentObject var subscriptions: SubscriptionStore
    @EnvironmentObject var coordinator: WalletCoordinator
    let manage: () -> Void
    let selectWallet: (ConnectionID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your AI usage").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("What’s left, and when it resets.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: manage) { Image(systemName: "slider.horizontal.3") }
                        .help("Manage subscription connections")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 225), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    subscriptionCard("Codex", icon: "terminal.fill", tint: .indigo,
                                     usage: subscriptions.codex, connected: subscriptions.codexConnected,
                                     message: subscriptions.codexMessage,
                                     connect: { Task { await subscriptions.connectCodex() } })
                    subscriptionCard("Claude", icon: "brain.head.profile", tint: .orange,
                                     usage: subscriptions.claude, connected: subscriptions.claudeConnected,
                                     message: subscriptions.claudeMessage,
                                     connect: { Task { await subscriptions.connectClaudeWebsite() } })
                }
                HStack {
                    Text("API wallets").font(.title3.weight(.semibold))
                    Spacer()
                    Text("Separate from subscription limits").font(.caption).foregroundStyle(.secondary)
                }
                if coordinator.activeConnections.isEmpty {
                    Text("Add a wallet with the + button in the toolbar.")
                        .foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(coordinator.activeConnections.filter { $0.providerId.kind == .wallet }) { connection in
                    Button { selectWallet(connection.id) } label: {
                        HStack(spacing: 16) {
                            Image(systemName: connection.providerId.systemImage)
                                .font(.title2).foregroundStyle(.teal)
                                .frame(width: 48, height: 48)
                                .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(connection.effectiveLabel).font(.headline)
                                Text(connection.state.statusSummary).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                if let observation = connection.lastObservation {
                                    ForEach(observation.balances) { balance in
                                        Text("\(balance.formattedTotal) \(balance.currency)")
                                            .font(.title2.weight(.semibold)).monospacedDigit()
                                    }
                                    Text("Updated \(observation.relativeAge)").font(.caption).foregroundStyle(.secondary)
                                } else { Text("Awaiting balance").foregroundStyle(.secondary) }
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.background, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
                    }.buttonStyle(.plain)
                }
                Label("Codex: 15-second checks · Claude website: 30-second checks", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Overview")
    }

    private func subscriptionCard(_ title: String, icon: String, tint: Color,
                                  usage: SubscriptionUsage?, connected: Bool, message: String?,
                                  connect: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.title3).foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                Text(title).font(.title3.bold())
                Spacer()
                if subscriptions.refreshing && title == "Codex" { ProgressView().controlSize(.small) }
            }
            if let usage, !usage.windows.isEmpty {
                ForEach(usage.windows) { window in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(window.title.replacingOccurrences(of: title + " · ", with: ""))
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
                        Text("\(window.usedPercent, specifier: "%.0f")% used").font(.caption).foregroundStyle(.secondary)
                        if let reset = window.resetsAt {
                            Label(reset > Date() ? "Resets \(reset.formatted(.relative(presentation: .numeric)))" : "Reset passed · awaiting update", systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                                .help(reset.formatted(date: .complete, time: .shortened))
                        } else { Text(window.resetText ?? "Reset time unavailable").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if message != nil {
                    Label("Refresh failed · showing last reading", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).help(message ?? "")
                }
                Text("\(subscriptions.freshness(usage, isClaude: title == "Claude")) · \(usage.observedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(connected ? "Waiting for limits" : "Connect your plan")
                        .font(.title2.weight(.semibold))
                    Text(connected
                         ? (title == "Claude" ? (subscriptions.claudeUsesWebsite ? "Sign in to Claude’s website connection to receive account-wide usage." : "Connect Claude’s website for automatic desktop and web usage updates.") : "Your usage will appear here after Codex responds.")
                         : "See remaining usage and reset times in one place.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if !connected {
                        Button("Connect \(title)", action: connect).buttonStyle(.borderedProminent).tint(tint)
                    } else if title == "Claude" {
                        Button("Open Claude website connection") { Task { await subscriptions.connectClaudeWebsite() } }.buttonStyle(.bordered)
                    } else {
                        Button("Retry") { Task { await subscriptions.refresh() } }
                    }
                    if let message, title == "Codex" {
                        Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(minHeight: 150, alignment: .topLeading)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 275, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(tint.opacity(0.18)))
    }
}
