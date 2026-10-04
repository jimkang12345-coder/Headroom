import SwiftUI
import HeadroomCore

struct MacWalletDetailView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    let connectionId: ConnectionID

    @State private var isShowingEditSheet: Bool = false
    @State private var isShowingDeleteConfirmation: Bool = false
    @State private var deleteErrorMessage: String? = nil

    private var connection: Connection? {
        coordinator.activeConnections.first { $0.id == connectionId }
    }

    var body: some View {
        Group {
            if let conn = connection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headerSection(for: conn)

                        if let deleteError = deleteErrorMessage {
                            errorBanner(title: "Deletion Failed", message: deleteError)
                        }

                        if conn.state.isAuthFailed {
                            errorBanner(title: "Authentication Failed", message: "Please check or replace your API key to resume balance updates.")
                        } else if conn.state.isRateLimited, let deadline = conn.state.rateLimitDeadline {
                            let relative = RelativeDateTimeFormatter().localizedString(for: deadline, relativeTo: Date())
                            infoBanner(title: "Rate Limit In Effect", message: "Provider requests are paused until \(relative).")
                        } else if case .offline(let attempt) = conn.state {
                            infoBanner(title: "Offline", message: offlineBannerMessage(attempt: attempt, lastReadingAt: conn.lastObservation?.capturedAt ?? conn.lastSuccessfulRefresh))
                        } else if case .keychainFailure = conn.state {
                            errorBanner(title: "Keychain Error", message: "Unable to access local credentials in Keychain.")
                        } else if case .persistenceFailure = conn.state {
                            errorBanner(title: "Storage Error", message: "Unable to write latest balance to local storage.")
                        }

                        if let observation = conn.lastObservation {
                            observationSection(observation: observation)
                        } else {
                            noObservationPlaceholder(for: conn)
                        }

                        actionSection(for: conn)
                    }
                    .padding(24)
                }
            } else {
                Text("Connection not found.")
                    .foregroundColor(.secondary)
            }
        }
        .sheet(isPresented: $isShowingEditSheet) {
            if let conn = connection {
                MacConnectionEditView(connection: conn)
                    .environmentObject(coordinator)
            }
        }
        .confirmationDialog(
            "Remove Connection",
            isPresented: $isShowingDeleteConfirmation,
            actions: {
                Button("Delete", role: .destructive) {
                    do {
                        try coordinator.removeConnection(id: connectionId)
                        deleteErrorMessage = nil
                    } catch {
                        deleteErrorMessage = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("Are you sure you want to remove this connection? Its stored credentials and balance history will be deleted.")
            }
        )
    }

    @ViewBuilder
    private func headerSection(for conn: Connection) -> some View {
        HStack(alignment: .top) {
            Image(systemName: conn.providerId.systemImage)
                .font(.system(size: 36))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(conn.effectiveLabel)
                    .font(.title2.bold())
                Text(conn.providerId.displayName)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    stateBadge(for: conn.state)

                    if let lastSuccess = conn.lastSuccessfulRefresh {
                        Text("Updated \(lastSuccess, style: .relative) ago")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if let lastAttempt = conn.lastAttemptedRefresh {
                        Text("Attempted \(lastAttempt, style: .time)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 4)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func stateBadge(for state: ConnectionState) -> some View {
        HStack(spacing: 4) {
            switch state {
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Ready")
                    .foregroundColor(.green)
            case .verifying:
                ProgressView().controlSize(.mini)
                Text("Verifying...")
                    .foregroundColor(.primary)
            case .offline:
                Image(systemName: "wifi.slash")
                    .foregroundColor(.secondary)
                Text("Offline")
                    .foregroundColor(.secondary)
            case .rateLimited:
                Image(systemName: "hourglass")
                    .foregroundColor(.orange)
                Text("Rate Limited")
                    .foregroundColor(.orange)
            case .authFailed:
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.red)
                Text("Auth Error")
                    .foregroundColor(.red)
            case .keychainFailure, .persistenceFailure:
                Image(systemName: "externaldrive.badge.xmark")
                    .foregroundColor(.red)
                Text("Storage Error")
                    .foregroundColor(.red)
            default:
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text(state.statusSummary)
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12))
        .cornerRadius(6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(state.statusSummary)")
    }

    @ViewBuilder
    private func errorBanner(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.bold())
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func infoBanner(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.bold())
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func observationSection(observation: WalletObservation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Balances by Currency")
                    .font(.headline)
                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: observation.isAvailable ? "bolt.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(observation.isAvailable ? .green : .red)
                    Text(observation.isAvailable ? "Sufficiency: Available" : "Sufficiency: Depleted")
                        .font(.caption.bold())
                        .foregroundColor(observation.isAvailable ? .green : .red)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((observation.isAvailable ? Color.green : Color.red).opacity(0.12))
                .cornerRadius(6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(observation.isAvailable ? "Account balance sufficiency: Available" : "Account balance sufficiency: Depleted")
            }

            ForEach(observation.balances) { balance in
                CurrencyCard(balance: balance)
            }
        }
    }

    @ViewBuilder
    private func noObservationPlaceholder(for conn: Connection) -> some View {
        VStack(spacing: 8) {
            Text("No balance data recorded yet.")
                .font(.callout)
                .foregroundColor(.secondary)
            Text("Click 'Refresh Now' or verify connection to fetch current balance.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func actionSection(for conn: Connection) -> some View {
        HStack(spacing: 12) {
            Button(action: {
                Task { await coordinator.refresh(connectionId: conn.id, forced: true) }
            }) {
                Label("Refresh Now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .disabled(coordinator.isRefreshing || !coordinator.isConnectionEligibleForRefresh(conn, trigger: .manualUserRefresh))

            Button(action: { isShowingEditSheet = true }) {
                Label("Edit Connection", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .disabled(coordinator.isDemoMode || coordinator.isStorageBlocked || coordinator.hasPendingIntent(for: conn.id))

            Spacer()

            Button(role: .destructive, action: { isShowingDeleteConfirmation = true }) {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(coordinator.isDemoMode || coordinator.isStorageBlocked || coordinator.hasPendingIntent(for: conn.id))
        }
        .padding(.top, 8)
    }

    private func offlineBannerMessage(attempt: Date, lastReadingAt: Date?) -> String {
        let failedText = "Last failed attempt at \(attempt.formatted(date: .omitted, time: .shortened))."
        if let readingDate = lastReadingAt {
            let readingText = "Last successful reading at \(readingDate.formatted(date: .omitted, time: .shortened))."
            return "Network unavailable. \(readingText) \(failedText)"
        } else {
            return "Network unavailable. No successful reading yet. \(failedText)"
        }
    }
}

struct CurrencyCard: View {
    let balance: CurrencyBalance

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(balance.currency)
                    .font(.title3.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .cornerRadius(4)

                Spacer()

                Text(balance.formattedTotal)
                    .font(.title.bold().monospacedDigit())
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Granted (Free Grant)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(balance.formattedGranted)
                        .font(.body.monospacedDigit())
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Topped-up (Cash Balance)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(balance.formattedToppedUp)
                        .font(.body.monospacedDigit())
                }
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(balance.currency) Balance: Total \(balance.formattedTotal), Granted \(balance.formattedGranted), Topped up \(balance.formattedToppedUp)")
    }
}
