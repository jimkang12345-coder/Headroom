import Foundation

@MainActor
public enum FixtureEnvironment {
    public static var requestedDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["HEADROOM_FIXTURE_DIR"], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    public static func makeCoordinator(fixtureDir: URL) -> WalletCoordinator {
        WalletCoordinator(
            secretStore: InMemorySecretStore(),
            storageManager: AppStorageManager(storageDirectory: fixtureDir),
            deepSeekClient: DeepSeekClient(transport: FixtureBalanceTransport()),
            isFixtureMode: true
        )
    }
}

/// Fixture account setup and refresh always stay offline, including invalid keys.
private struct FixtureBalanceTransport: NetworkTransport {
    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let valid = request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-valid"
        let body = valid
            ? #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12.5000","granted_balance":"2.5000","topped_up_balance":"10.0000"}]}"#
            : "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 401,
                                       httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}
