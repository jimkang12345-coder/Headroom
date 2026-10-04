import SwiftUI
import AppKit
import HeadroomCore

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    var coordinator: WalletCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            coordinator?.handleForegroundResume()
        }
    }

    @objc private func handleWake() {
        Task { @MainActor in
            coordinator?.handleSystemWake()
        }
    }

    @objc private func handleSleep() {
        Task { @MainActor in
            coordinator?.pauseScheduling()
        }
    }
}

@main
struct HeadroomMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var coordinator: WalletCoordinator
    @StateObject private var subscriptions = SubscriptionStore()
    @AppStorage("appearanceMode", store: HeadroomPreferences.defaults) private var appearanceMode: String = "system"

    init() {
        let coord: WalletCoordinator
        #if DEBUG
        if let fixtureDir = FixtureEnvironment.requestedDirectory {
            coord = FixtureEnvironment.makeCoordinator(fixtureDir: fixtureDir)
        } else {
            let storageDir = AppStorageManager.defaultStorageDirectory()
            let storage = AppStorageManager(storageDirectory: storageDir)
            let secretStore = KeychainSecretStore()
            coord = WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage
            )
        }
        #else
            let storageDir = AppStorageManager.defaultStorageDirectory()
            let storage = AppStorageManager(storageDirectory: storageDir)
            let secretStore = KeychainSecretStore()
            coord = WalletCoordinator(
                secretStore: secretStore,
                storageManager: storage
            )
        #endif
        _coordinator = StateObject(wrappedValue: coord)
        appDelegate.coordinator = coord
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }

    var body: some Scene {
        WindowGroup("Headroom", id: "main") {
            MacContentView()
                .environmentObject(coordinator)
                .environmentObject(subscriptions)
                .task { subscriptions.setSuspended(coordinator.isDemoMode || coordinator.isFixtureMode) }
                .onChange(of: coordinator.isDemoMode) { _, value in
                    subscriptions.setSuspended(value || coordinator.isFixtureMode)
                }
                .preferredColorScheme(preferredColorScheme)
                .frame(minWidth: 700, minHeight: 450)
                .onAppear {
                    appDelegate.coordinator = coordinator
                }
        }
        .commands {
            SidebarCommands()
        }

        MenuBarExtra {
            subscriptionMenu
        } label: {
            Text(menuTitle("Codex", usage: subscriptions.codex))
                .monospacedDigit()
                .help("Codex remaining capacity · most-used limit window")
        }
        .menuBarExtraStyle(.window)

        MenuBarExtra {
            subscriptionMenu
        } label: {
            Text(menuTitle("Claude", usage: subscriptions.claude, windowID: "five_hour"))
                .monospacedDigit()
                .help("Claude remaining capacity · 5-hour session")
        }
        .menuBarExtraStyle(.window)
    }

    private func menuTitle(_ name: String, usage: SubscriptionUsage?, windowID: String? = nil) -> String {
        guard !coordinator.isDemoMode, !coordinator.isFixtureMode else { return "\(name) —" }
        let stale = usage.map { subscriptions.displayTime.timeIntervalSince($0.observedAt) > 120 } ?? false
        return "\(name) \(stale ? "~" : "")\(QuotaPresentation.menuPercentage(usage, windowID: windowID))"
    }

    private var subscriptionMenu: some View {
        MacMenuBarView()
            .environmentObject(coordinator)
            .environmentObject(subscriptions)
            .task { subscriptions.setSuspended(coordinator.isDemoMode || coordinator.isFixtureMode) }
            .onChange(of: coordinator.isDemoMode) { _, value in
                subscriptions.setSuspended(value || coordinator.isFixtureMode)
            }
            .preferredColorScheme(preferredColorScheme)
            .onAppear { appDelegate.coordinator = coordinator }
    }
}
