import SwiftUI
import HeadroomCore

struct MacConnectionSetupView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: ProviderID = .openai
    @State private var userLabel: String = ""
    @State private var apiKey: String = ""
    @State private var monthlyBudget: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Form {
                Section {
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(ProviderID.allCases.filter { $0.kind != .subscription }) { provider in
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
                    SecureField(selectedProvider.kind == .apiCost ? "Organization Admin API Key" : "API Key", text: $apiKey, prompt: Text("Enter key for this API tracker"))
                        .disabled(!selectedProvider.isImplemented || isSaving)

                    Text(credentialExplanation)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if selectedProvider.kind == .apiCost {
                    Section("Optional local budget") {
                        TextField("Monthly target (USD)", text: $monthlyBudget, prompt: Text("Leave blank to track spend only"))
                            .disabled(isSaving)
                        Text("A target saved on this Mac. It does not set a provider spending limit or stop API requests.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(selectedProvider == .anthropic
                             ? "Anthropic reports API cost in daily buckets and excludes Priority Tier costs. Reports may lag; this is not remaining credit or Claude Code subscription usage."
                             : "OpenAI reports organization API spend. Reports may lag; this is not remaining credit or Codex subscription usage.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
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
        .frame(width: 520, height: 570)
        .interactiveDismissDisabled(isSaving)
    }

    private var header: some View {
        HStack {
            Text("Add optional API tracker")
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

    private var credentialExplanation: String {
        if coordinator.isFixtureMode {
            let marker = selectedProvider == .openai ? "sk-admin-fixture-valid" : selectedProvider == .anthropic ? "sk-ant-admin01-fixture-valid" : "fixture-valid"
            return "Offline synthetic fixture only. Use \(marker). Never enter a real key."
        }
        switch selectedProvider {
        case .openai:
            return "Requires an OpenAI organization Admin key. This credential has organization privileges; Headroom only reads cost reports from api.openai.com and stores the key in macOS Keychain. A regular project key is insufficient."
        case .anthropic:
            return "Requires an Anthropic organization Admin key for Claude Console API costs. Headroom only reads reports from api.anthropic.com and stores the key in macOS Keychain. Workspace keys and individual Claude subscriptions are insufficient."
        default:
            return "Stored in macOS Keychain and sent to this provider to read your API balance. Keys are excluded from backups and logs."
        }
    }

    private var canSave: Bool {
        selectedProvider.kind != .subscription && selectedProvider.isImplemented && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                    apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    monthlyBudget: selectedProvider.kind == .apiCost ? try parseMonthlyBudget(monthlyBudget) : nil
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
    @State private var monthlyBudget: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    init(connection: Connection) {
        self.connection = connection
        _userLabel = State(initialValue: connection.userLabel)
        _monthlyBudget = State(initialValue: connection.monthlyBudget.map { NSDecimalNumber(decimal: $0).stringValue } ?? "")
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

                if connection.providerId.kind == .apiCost {
                    Section("Local monthly target (USD)") {
                        TextField("Target", text: $monthlyBudget, prompt: Text("Blank means spend only"))
                            .disabled(isSaving)
                        Text("A local reference target, not a provider-enforced spending limit.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section("Replace API Key (Optional)") {
                    SecureField("New API Key", text: $newApiKey, prompt: Text("Leave blank to keep existing key"))
                        .disabled(isSaving)

                    Text("Entering a new key retires the previous credential and starts fresh API report verification. Cost reports require an organization Admin key.")
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
        .frame(width: 520, height: 500)
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
                    newApiKey: keyToPass,
                    monthlyBudget: connection.providerId.kind == .apiCost ? try parseMonthlyBudget(monthlyBudget) : nil
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private func parseMonthlyBudget(_ text: String) throws -> Decimal? {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return nil }
    let amount = try CurrencyBalance.parseDecimalStrict(clean, fieldName: "monthly_budget")
    guard amount > 0 else { throw CoordinatorError.invalidBudget }
    return amount
}
