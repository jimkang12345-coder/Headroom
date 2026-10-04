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
            openAICostClient: OpenAICostClient(transport: FixtureCostTransport()),
            anthropicCostClient: AnthropicCostClient(transport: FixtureCostTransport()),
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

/// Organization reports in fixture mode also stay offline. Only documented synthetic keys succeed.
private struct FixtureCostTransport: NetworkTransport {
    func send(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let openAI = request.url?.host == "api.openai.com"
        let key = openAI ? request.value(forHTTPHeaderField: "Authorization") : request.value(forHTTPHeaderField: "x-api-key")
        let valid = openAI ? key == "Bearer sk-admin-fixture-valid" : key == "sk-ant-admin01-fixture-valid"
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        var body: [String: Any] = ["has_more": false, "next_page": NSNull()]
        if openAI {
            let start = Int(query["start_time"] ?? "") ?? 0
            let end = Int(query["end_time"] ?? "") ?? start + 1
            let bucketEnd = min(start + 86400, end)
            body["object"] = "page"
            body["data"] = [["object": "bucket", "start_time": start, "end_time": bucketEnd,
                              "results": [["object": "organization.costs.result", "amount": ["value": 18.25, "currency": "usd"]]]]]
        } else {
            let format = ISO8601DateFormatter()
            let start = format.date(from: query["starting_at"] ?? "") ?? Date()
            let end = format.date(from: query["ending_at"] ?? "") ?? start
            // No invented complete daily bucket during the first day of a UTC month.
            body["data"] = end.timeIntervalSince(start) >= 86400
                ? [["starting_at": format.string(from: start), "ending_at": format.string(from: start.addingTimeInterval(86400)),
                    "results": [["amount": "925", "currency": "USD"]]]]
                : []
        }
        let data = try JSONSerialization.data(withJSONObject: valid ? body : [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 401, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}
