import SwiftUI
import HeadroomCore

@main
struct HeadroomIOSApp: App {
    @StateObject private var coordinator: WalletCoordinator
    @Environment(\.scenePhase) private var scenePhase
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
        #if DEBUG
        if CommandLine.arguments.contains("-demoMode") {
            coord.setDemoMode(true)
        }
        #endif
        coord.pauseScheduling()
        _coordinator = StateObject(wrappedValue: coord)
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
        WindowGroup {
            IOSContentView()
                .environmentObject(coordinator)
                .preferredColorScheme(preferredColorScheme)
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            switch newPhase {
            case .active:
                coordinator.resumeScheduling()
            case .inactive, .background:
                coordinator.pauseScheduling()
            @unknown default:
                break
            }
        }
    }
}
