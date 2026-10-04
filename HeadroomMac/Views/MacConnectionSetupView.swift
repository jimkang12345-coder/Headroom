import SwiftUI
import HeadroomCore

struct MacConnectionSetupView: View {
    @State private var showingSubscriptions = false
    @EnvironmentObject var subscriptions: SubscriptionStore
    @EnvironmentObject var coordinator: WalletCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: ProviderID = .deepseek
    @State private var userLabel: String = ""
    @State private var apiKey: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Form {
                Section {
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(ProviderID.allCases) { provider in
                            HStack {
                                Text(provider.displayName)
                                if !provider.isImplemented {
                                    Text("(\(provider.statusDescription))")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .tag(provider)
                        }
                    }
                    .disabled(isSaving)

                    if isSaving {
                        Text("Saving connection…").font(.caption)
                    }
                    if !selectedProvider.isImplemented {
                        Text("\(selectedProvider.displayName) integration is coming soon.")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    TextField("Account Label (optional)", text: $userLabel, prompt: Text("e.g. Work, Personal"))
                        .disabled(isSaving)
                }

                Section {
                    SecureField("API Key", text: $apiKey, prompt: Text("Enter API key"))
                        .disabled(!selectedProvider.isImplemented || isSaving)

                    Text(coordinator.isFixtureMode ? "Synthetic fixture only. Use fixture-valid or fixture-invalid. Never enter a real key." : "Stored locally in macOS Keychain. Used exclusively to query your balance from \(selectedProvider == .deepseek ? "api.deepseek.com" : "the provider"). Never logged or sent to third parties.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let error = errorMessage {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()
            footer
        }
        .frame(width: 480, height: 380)
        .interactiveDismissDisabled(isSaving)
        .sheet(isPresented: $showingSubscriptions) { MacSubscriptionsView().environmentObject(subscriptions) }
    }

    private var header: some View {
        HStack {
            Button("Connect Codex or Claude") { showingSubscriptions = true }
                .disabled(coordinator.isDemoMode || coordinator.isFixtureMode)
            Text("Add Wallet")
                .font(.headline)
            Spacer()
        }
        .padding()
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(isSaving)

            Spacer()

            if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 8)
            }

            Button("Save & Verify") {
                saveConnection()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSave || isSaving)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var canSave: Bool {
        selectedProvider.isImplemented && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveConnection() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil

        Task {
            do {
                _ = try await coordinator.addConnection(
                    provider: selectedProvider,
                    userLabel: userLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                    apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

struct MacConnectionEditView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @Environment(\.dismiss) private var dismiss

    let connection: Connection

    @State private var userLabel: String = ""
    @State private var newApiKey: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    init(connection: Connection) {
        self.connection = connection
        _userLabel = State(initialValue: connection.userLabel)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit Connection")
                    .font(.headline)
                Spacer()
            }
            .padding()

            Divider()

            Form {
                Section("Details") {
                    LabeledContent("Provider", value: connection.providerId.displayName)
                    TextField("Account Label", text: $userLabel)
                        .disabled(isSaving)
                }

                Section("Replace API Key (Optional)") {
                    SecureField("New API Key", text: $newApiKey, prompt: Text("Leave blank to keep existing key"))
                        .disabled(isSaving)

                    Text("Entering a new key updates your credential in Keychain and starts a fresh balance observation generation.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let error = errorMessage {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Spacer()

                if isSaving {
                    ProgressView().controlSize(.small)
                }

                Button("Save Changes") {
                    saveChanges()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 480, height: 350)
        .interactiveDismissDisabled(isSaving)
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
