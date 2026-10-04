import SwiftUI
import HeadroomCore
#if os(macOS)
import AppKit
#endif

struct MacSettingsView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @Environment(\.dismiss) private var dismiss

    @AppStorage("appearanceMode", store: HeadroomPreferences.defaults) private var appearanceMode: String = "system"
    @State private var exportStatusMessage: String?
    @State private var isShowingFileImporter: Bool = false
    @State private var importErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearanceMode) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("App Theme")
                }

                Section("Testing & Demo Mode") {
                    Toggle("Demo Mode Active", isOn: Binding(
                        get: { coordinator.isDemoMode },
                        set: { coordinator.setDemoMode($0) }
                    ))
                    .accessibilityLabel("Toggle Demo Mode")

                    Text("Demo Mode displays synthetic limits and balances and suspends provider refresh. Requests already started may finish. Use a fixture launch for isolated screenshots; exiting Demo Mode restores your local account view.")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if coordinator.isDemoMode {
                        Text("Modifications and imports are disabled in Demo Mode. Export generates labeled synthetic data.")
                            .font(.caption2.bold())
                            .foregroundColor(.orange)
                    }
                }

                Section("Local Data & Storage") {
                    LabeledContent("Storage Location", value: coordinator.isFixtureMode ? "Isolated test folder" : coordinator.storageManager.storageDirectory.path)
                        .font(.caption)

                    LabeledContent("Stored Connections", value: "\(coordinator.connections.count)")

                    HStack(spacing: 12) {
                        Button("Export JSON") {
                            exportData()
                        }
                        .help(coordinator.isDemoMode ? "Export labeled synthetic demo data" : "Export your connections and observations (credential-free)")

                        Button("Import JSON") {
                            isShowingFileImporter = true
                        }
                        .disabled(coordinator.isDemoMode)
                        .help(coordinator.isDemoMode ? "Exit Demo Mode to import accounts" : "Import connections and observations from a JSON backup")
                    }
                    .padding(.top, 4)

                    Text("Backups include account labels, API reports, budget targets and balance history. Keep them private; API keys are excluded.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let status = exportStatusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                    if let importErr = importErrorMessage {
                        Text(importErr)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section("Refresh Policy") {
                    Text("Codex checks on a 15-second success cadence with bounded retries while active and awake. Claude Code updates when its local status-line feed reports limits. Optional API trackers refresh every 5 minutes; daily cost reports can lag. Provider backoff and Retry-After are respected.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("About Headroom") {
                    LabeledContent("App", value: "Headroom")
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Private data", value: "History and API targets on this Mac; keys in Keychain")
                    Text("Refreshing contacts the provider you connected. Website sign-in pages and official local clients have their own network activity. Disconnect Claude to remove Headroom's website sign-in session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .frame(width: 520, height: 480)
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result: result)
        }
    }

    private func exportData() {
        do {
            let data = try coordinator.exportSnapshot()
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.json]
            savePanel.nameFieldStringValue = "Headroom-Snapshot-\(Int(Date().timeIntervalSince1970)).json"
            if savePanel.runModal() == .OK, let url = savePanel.url {
                try data.write(to: url)
                exportStatusMessage = "Exported successfully to \(url.lastPathComponent)"
            }
        } catch {
            exportStatusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func readBoundedSnapshotData(from url: URL, maxBytes: Int = 5 * 1024 * 1024) throws -> Data {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let resources = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = resources?.fileSize, fileSize > maxBytes {
            throw StorageError.fileTooLarge(size: fileSize)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        guard let data = try handle.read(upToCount: maxBytes + 1) else {
            throw StorageError.corruptedData
        }
        if data.count > maxBytes {
            throw StorageError.fileTooLarge(size: data.count)
        }
        return data
    }

    private func handleImport(result: Result<[URL], Error>) {
        do {
            guard let selectedURL = try result.get().first else { return }
            let data = try readBoundedSnapshotData(from: selectedURL)
            try coordinator.importSnapshot(data)
            exportStatusMessage = "Imported connections and observations successfully."
            importErrorMessage = nil
        } catch {
            importErrorMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
