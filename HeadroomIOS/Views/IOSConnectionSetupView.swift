import SwiftUI
import HeadroomCore

struct IOSConnectionSetupView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: ProviderID = .deepseek
    @State private var userLabel: String = ""
    @State private var apiKey: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Select Provider", selection: $selectedProvider) {
                        ForEach(ProviderID.allCases) { provider in
                            Text(provider.displayName).tag(provider)
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
                }

                Section("Account Label (Optional)") {
                    TextField("e.g. Work, Personal", text: $userLabel)
                        .disabled(isSaving)
                }

                Section(
                    header: Text("API Key"),
                    footer: Text(coordinator.isFixtureMode ? "Synthetic fixture only. Use fixture-valid or fixture-invalid. Never enter a real key." : "Stored locally in the iOS Keychain. Only used to query your balance from \(selectedProvider == .deepseek ? "api.deepseek.com" : "the provider").")
                ) {
                    SecureField("Enter API Key", text: $apiKey)
                        .disabled(!selectedProvider.isImplemented || isSaving)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let err = errorMessage {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(err)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("Add Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            save()
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private var canSave: Bool {
        selectedProvider.isImplemented && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
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
