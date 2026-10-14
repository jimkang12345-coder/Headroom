import XCTest
@testable import HeadroomCore

final class LocalUsageCatalogTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/saminyasar", isDirectory: true)

    func testT3SettingsKeepsEnabledAccountsAndSkipsDisabledOnes() {
        let json = """
        {"providerInstances":{
          "codex":{"driver":"codex","displayName":"Unused","enabled":false,"config":{"homePath":""}},
          "codex_cli":{"driver":"codex","displayName":"Codex CLI","enabled":true,"config":{"homePath":"/Users/saminyasar/.codex"}},
          "outside":{"driver":"codex","displayName":"Elsewhere","enabled":true,"config":{"homePath":"/tmp/codex"}},
          "claudeAgent":{"driver":"claudeAgent","displayName":"Claude 200","enabled":true,"config":{"homePath":""}},
          "claude_personal":{"driver":"claudeAgent","displayName":"Claude 100","enabled":true,"config":{"homePath":"/Users/saminyasar/.claude_personal"}},
          "grok":{"driver":"grok","enabled":true,"config":{"binaryPath":"grok"}},
          "hermes":{"driver":"grok","displayName":"Hermes","enabled":true,"config":{"binaryPath":"/Users/saminyasar/.t3/hermes/hermes-t3"}}
        }}
        """.data(using: .utf8)!
        let accounts = LocalUsageCatalog.accounts(t3Settings: json, home: home)
        XCTAssertEqual(accounts.map(\.kind), [.claude, .claude, .codex, .grok, .hermes])
        XCTAssertEqual(accounts.map(\.label), ["Claude 200", "Claude 100", "Codex CLI", "Grok", "Hermes"])
        XCTAssertEqual(accounts[0].homePath, "/Users/saminyasar/.claude")
        XCTAssertEqual(accounts[1].homePath, "/Users/saminyasar/.claude_personal")
        XCTAssertNil(accounts[3].homePath)
        XCTAssertFalse(accounts.contains { $0.homePath == "/tmp/codex" })
        XCTAssertFalse(accounts.contains { $0.label == "Unused" })
    }

    func testGrokSpendSumsTurnsInsideTheWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        let earlier = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3 * 24 * 3600))
        let ancient = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30 * 24 * 3600))
        let file = """
        {"turns":[
          {"endedAt":"\(today)","costUsdTicks":10000000000},
          {"endedAt":"\(earlier)","costUsdTicks":20000000000},
          {"endedAt":"\(ancient)","costUsdTicks":900000000000}
        ]}
        """.data(using: .utf8)!
        let spend = GrokSpend.summarize([file, Data("nope".utf8)], now: now, calendar: calendar)
        XCTAssertEqual(spend.todayUSD, 1)
        XCTAssertEqual(spend.weekUSD, 3)
        XCTAssertEqual(spend.turnCount, 2)
    }
}
