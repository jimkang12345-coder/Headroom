import SwiftUI
import HeadroomCore

struct IOSWalletDetailView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let connectionId: ConnectionID

    @State private var isShowingEditSheet: Bool = false
    @State private var isShowingDeleteConfirmation: Bool = false
    @State private var deleteErrorMessage: String? = nil

    init(connectionId: ConnectionID) {
        self.connectionId = connectionId
        #if DEBUG
        if CommandLine.arguments.contains("-showEditSheet") {
            _isShowingEditSheet = State(initialValue: true)
        }
        #endif
    }

    private var connection: Connection? {
        coordinator.activeConnections.first { $0.id == connectionId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                IOSRecoveryNotice()

                if let conn = connection {
                    headerView(for: conn)

                    if let deleteErr = deleteErrorMessage {
                        errorBanner(title: "Deletion Failed", message: deleteErr)
                    }

                    if conn.state.isAuthFailed {
                        errorBanner(title: "Authentication Failed", message: "Please tap 'Edit / Change Key' below to update your API key.")
                    } else if conn.state.isRateLimited, let deadline = conn.state.rateLimitDeadline {
                        let relative = RelativeDateTimeFormatter().localizedString(for: deadline, relativeTo: Date())
                        infoBanner(title: "Rate Limited", message: "Provider requests paused until \(relative).")
                    } else if case .offline(let attempt) = conn.state {
                        infoBanner(title: "Offline", message: offlineBannerMessage(attempt: attempt, lastReadingAt: conn.lastObservation?.capturedAt ?? conn.lastSuccessfulRefresh))
                    } else if case .awaitingVerification(let reason) = conn.state {
                        infoBanner(title: "Setup Required", message: reason.description)
                    }

                    if let obs = conn.lastObservation {
                        balancesView(observation: obs)
                    } else {
                        noBalancesView(for: conn)
                    }

                    actionsView(for: conn)
                } else {
                    Text("Connection not found.")
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)
        }
        .onChange(of: connection != nil) { _, exists in
            if !exists { dismiss() }
        }
        .navigationTitle(connection?.effectiveLabel ?? "Wallet")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingEditSheet) {
            if let conn = connection {
                IOSEditConnectionSheet(connection: conn)
                    .environmentObject(coordinator)
            }
        }
        .confirmationDialog(
            "Remove Connection",
            isPresented: $isShowingDeleteConfirmation,
            actions: {
                Button("Delete Connection", role: .destructive) {
                    do {
                        try coordinator.removeConnection(id: connectionId)
                        deleteErrorMessage = nil
                        dismiss()
                    } catch {
                        deleteErrorMessage = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("This will delete the local connection and its Keychain credential.")
            }
        )
    }

    @ViewBuilder
    private func headerView(for conn: Connection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            adaptiveRow {
                Image(systemName: conn.providerId.systemImage)
                    .font(.largeTitle)
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(conn.effectiveLabel)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text(conn.providerId.displayName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            }

            adaptiveRow {
                Text(conn.state.statusSummary)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(6)

                if let lastSuccess = conn.lastSuccessfulRefresh {
                    Text("Updated \(lastSuccess, style: .relative) ago")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibleHeaderLabel(for: conn))
    }

    private func accessibleHeaderLabel(for conn: Connection) -> String {
        var label = "\(conn.effectiveLabel), \(conn.providerId.displayName), Status: \(conn.state.statusSummary)"
        if let lastSuccess = conn.lastSuccessfulRefresh {
            let relative = RelativeDateTimeFormatter().localizedString(for: lastSuccess, relativeTo: Date())
            label += ", Updated \(relative)"
        }
        return label
    }

    @ViewBuilder
    private func errorBanner(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func infoBanner(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(.orange)
                Text(message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
    }

    private var adaptiveRow: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
    }

    private func amountText(_ value: String, prominent: Bool = false) -> some View {
        Text(value)
            .font(prominent ? .title2.bold().monospacedDigit() : .caption.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .allowsTightening(true)
            .frame(maxWidth: .infinity, alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
    }

    @ViewBuilder
    private func balancesView(observation: WalletObservation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            adaptiveRow {
                Text("Balances")
                    .font(.headline)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }

                Label(observation.isAvailable ? "Sufficiency: Available" : "Sufficiency: Depleted",
                      systemImage: observation.isAvailable ? "bolt.circle.fill" : "exclamationmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundColor(observation.isAvailable ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((observation.isAvailable ? Color.green : Color.red).opacity(0.12))
                    .cornerRadius(6)
            }

            ForEach(observation.balances) { b in
                VStack(alignment: .leading, spacing: 10) {
                    adaptiveRow {
                        Text(b.currency)
                            .font(.headline)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .cornerRadius(6)
                            .fixedSize()
                        amountText(b.formattedTotal, prominent: true)
                    }

                    Divider()

                    adaptiveRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Free Grant")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(b.formattedGranted)
                                .font(.caption.monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.45)
                                .allowsTightening(true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                            Text("Topped-Up Cash")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            amountText(b.formattedToppedUp)
                        }
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(b.currency): Total \(b.formattedTotal), Grant \(b.formattedGranted), Cash \(b.formattedToppedUp)")
            }
        }
    }

    @ViewBuilder
    private func noBalancesView(for conn: Connection) -> some View {
        VStack(spacing: 8) {
            Text("No balance readings available.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Tap Refresh or configure API key.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func actionsView(for conn: Connection) -> some View {
        VStack(spacing: 12) {
            Button(action: {
                Task { await coordinator.refresh(connectionId: conn.id, forced: true) }
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh Balance")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(coordinator.isRefreshing || !coordinator.isConnectionEligibleForRefresh(conn, trigger: .manualUserRefresh))

            Button(action: { isShowingEditSheet = true }) {
                HStack {
                    Image(systemName: "pencil")
                    Text("Edit Label / Change Key")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(coordinator.isDemoMode || coordinator.isStorageBlocked || coordinator.hasPendingIntent(for: conn.id))

            Button(role: .destructive, action: { isShowingDeleteConfirmation = true }) {
                HStack {
                    Image(systemName: "trash")
                    Text("Remove Connection")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(coordinator.isDemoMode || coordinator.isStorageBlocked || coordinator.hasPendingIntent(for: conn.id))
        }
        .padding(.top, 12)
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

struct IOSEditConnectionSheet: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @Environment(\.dismiss) private var dismiss

    let connection: Connection

    @State private var userLabel: String = ""
    @State private var newApiKey: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil

    init(connection: Connection) {
        self.connection = connection
        _userLabel = State(initialValue: connection.userLabel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account Details") {
                    LabeledContent("Provider", value: connection.providerId.displayName)
                    TextField("Account Label", text: $userLabel)
                        .disabled(isSaving)
                }

                Section("API Key") {
                    SecureField("New API Key", text: $newApiKey, prompt: Text("Leave blank to keep existing key"))
                        .disabled(isSaving)

                    Text("Entering a new key updates your credential in Keychain and starts a fresh balance observation generation.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Edit Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func saveChanges() {
        isSaving = true
        errorMessage = nil

        let trimmedKey = newApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyToPass = trimmedKey.isEmpty ? nil : trimmedKey

        Task {
            do {
                try await coordinator.updateConnection(
                    id: connection.id,
                    userLabel: userLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                    newApiKey: keyToPass
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
