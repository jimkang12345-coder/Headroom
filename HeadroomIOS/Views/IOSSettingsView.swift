import SwiftUI
import HeadroomCore

struct IOSSettingsView: View {
    @EnvironmentObject var coordinator: WalletCoordinator
    @AppStorage("appearanceMode", store: HeadroomPreferences.defaults) private var appearanceMode: String = "system"

    @State private var isShowingShareSheet: Bool = false
    @State private var exportURL: URL?
    @State private var isShowingFilePicker: Bool = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if coordinator.showsRecoveryNotice {
                    Section { IOSRecoveryNotice() }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearanceMode) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section(
                    header: Text("Testing & Demo Mode"),
                    footer: Text(coordinator.isDemoMode ? "Modifications and imports are disabled in Demo Mode. Exiting restores your real store." : "Demo Mode shows synthetic balances. A normal launch may already have loaded private state or started provider work before you switch modes.")
                ) {
                    Toggle("Demo Mode Active", isOn: Binding(
                        get: { coordinator.isDemoMode },
                        set: { coordinator.setDemoMode($0) }
                    ))
                    .accessibilityLabel("Toggle Demo Mode")
                }

                Section("Local Storage & Backup") {
                    LabeledContent("Stored Connections", value: "\(coordinator.connections.count)")

                    Button(action: exportData) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text(coordinator.isDemoMode ? "Export Synthetic Demo (JSON)" : "Export Backup (JSON)")
                        }
                    }

                    Button(action: { isShowingFilePicker = true }) {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import Backup (JSON)")
                        }
                    }
                    .disabled(coordinator.isDemoMode)

                    if let status = statusMessage {
                        Text(status)
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                    if let err = errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                Section("Refresh Policy") {
                    Text("Auto-refresh polls balances every 5 minutes while the app is foregrounded. On app resume, stale balances (> 5m) refresh once automatically. Backoff and Retry-After headers from providers are respected automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("About Headroom") {
                    LabeledContent("App", value: "Headroom")
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Privacy", value: "Direct provider requests only; credentials in local Keychain")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $isShowingShareSheet) {
                if let url = exportURL {
                    ShareSheet(activityItems: [url])
                }
            }
            .fileImporter(
                isPresented: $isShowingFilePicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result: result)
            }
        }
    }

    private func exportData() {
        do {
            let data = try coordinator.exportSnapshot()
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("Headroom-Backup-\(Int(Date().timeIntervalSince1970)).json")
            try PrivateSnapshotExporter.write(data, to: tempURL)
            exportURL = tempURL
            isShowingShareSheet = true
            statusMessage = coordinator.isDemoMode ? "Synthetic demo backup ready for sharing." : "Backup ready for sharing."
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
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
            statusMessage = "Imported connections and observations successfully."
            errorMessage = nil
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
