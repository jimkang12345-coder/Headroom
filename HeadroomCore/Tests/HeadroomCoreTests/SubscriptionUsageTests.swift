import XCTest
@testable import HeadroomCore

final class SubscriptionUsageTests: XCTestCase {
    func testCodexPrefersAllBucketsAndUsesDurationNotSlot() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":35,"windowDurationMins":10080,"resetsAt":2000000000}},"other":{"primary":{"usedPercent":10,"windowDurationMins":300},"secondary":{"usedPercent":20}}}}"#.utf8)
        let result = try SubscriptionUsage.codex(data)
        XCTAssertEqual(result.windows.count, 3)
        XCTAssertEqual(result.windows[0].remainingPercent, 65)
        XCTAssertTrue(result.windows[0].title.contains("Weekly"))
        XCTAssertEqual(result.plan, "pro")
        XCTAssertEqual(result.windows[0].resetsAt, Date(timeIntervalSince1970: 2000000000))
        XCTAssertTrue(result.isComplete)
    }
    func testUnknownQuotaIsNotZeroUsage() throws {
        XCTAssertTrue(try SubscriptionUsage.codex(Data(#"{"rateLimits":{"primary":{"usedPercent":null}}}"#.utf8)).windows.isEmpty)
        XCTAssertTrue(try SubscriptionUsage.claude(Data(#"{"context_window":{"used_percentage":42}}"#.utf8)).windows.isEmpty)
        XCTAssertTrue(try SubscriptionUsage.claude(Data(#"{"rate_limits":null}"#.utf8)).windows.isEmpty)
    }
    func testClaudePercentageAndMissingReset() throws {
        let result = try SubscriptionUsage.claude(Data(#"{"rate_limits":{"five_hour":{"used_percentage":25},"seven_day":{"used_percentage":100,"resets_at":2000000000}}}"#.utf8))
        XCTAssertEqual(result.windows.map(\.remainingPercent), [75, 0])
        XCTAssertNil(result.windows.first?.resetsAt)
    }

    func testClaudeOAuthUsesLimitPercentsAndParsesResets() throws {
        let payload = #"{"five_hour":{"utilization":99,"resets_at":"2020-01-01T00:00:00Z"},"seven_day":{"utilization":1},"limits":[{"kind":"session","percent":15,"resets_at":"2026-10-14T22:49:59.968016+00:00"},{"kind":"weekly_all","percent":0,"resets_at":1800000000},{"kind":"weekly_scoped","percent":40}]}"#
        let usage = try SubscriptionUsage.claudeOAuth(Data(payload.utf8), now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(usage.windows.map(\.id), ["five_hour", "seven_day"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [15, 0])
        XCTAssertEqual(usage.windows.map(\.remainingPercent), [85, 100])
        let base = ISO8601DateFormatter()
        base.formatOptions = [.withInternetDateTime]
        let expectedReset = base.date(from: "2026-10-14T22:49:59Z")!.addingTimeInterval(0.968)
        XCTAssertEqual(usage.windows[0].resetsAt!.timeIntervalSince1970, expectedReset.timeIntervalSince1970, accuracy: 0.0005)
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(usage.isComplete)
    }

    func testClaudeOAuthFallsBackToUtilizationAndRejectsOutOfRange() throws {
        let usage = try SubscriptionUsage.claudeOAuth(Data(#"{"five_hour":{"utilization":15},"seven_day":{"utilization":150}}"#.utf8))
        XCTAssertEqual(usage.windows.map(\.usedPercent), [15])
        XCTAssertEqual(usage.unavailableWindowIDs, ["seven_day"])
        XCTAssertFalse(usage.isComplete)
        XCTAssertTrue(try SubscriptionUsage.claudeOAuth(Data("{}".utf8)).windows.isEmpty)
        XCTAssertThrowsError(try SubscriptionUsage.claudeOAuth(Data("bad".utf8)))
    }

    func testClaudeCredentialServiceUsesTheDefaultNameOrPathHash() {
        let standard = URL(fileURLWithPath: "/tmp/default-claude")
        XCTAssertEqual(ClaudeCredentialLocator.service(configDirectory: standard, defaultDirectory: standard), "Claude Code-credentials")
        let other = URL(fileURLWithPath: "/tmp/claude-home")
        XCTAssertEqual(ClaudeCredentialLocator.service(configDirectory: other, defaultDirectory: standard), "Claude Code-credentials-ee668b60")
    }
    func testInvalidValuesAndLegacyFallback() throws {
        let result = try SubscriptionUsage.codex(Data(#"{"rateLimitsByLimitId":{},"rateLimits":{"primary":{"usedPercent":101},"secondary":{"usedPercent":0}}}"#.utf8))
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].remainingPercent, 100)
        XCTAssertEqual(result.unavailableWindowIDs, ["codex.primary"])
        XCTAssertFalse(result.isComplete)
        XCTAssertThrowsError(try SubscriptionUsage.claude(Data("bad".utf8)))
    }

    func testCodexKeepsKnownWindowWhenOtherReportedWindowIsUnusable() throws {
        for malformed in ["{}", #"{"usedPercent":null}"#, #"{"usedPercent":-1}"#, #"{"usedPercent":101}"#, #"{"usedPercent":"unknown"}"#, "[]", "true"] {
            let data = Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":5},\"secondary\":\(malformed)}}".utf8)
            let usage = try SubscriptionUsage.codex(data)
            XCTAssertEqual(usage.windows.map(\.usedPercent), [5], malformed)
            XCTAssertEqual(usage.unavailableWindowIDs, ["codex.secondary"], malformed)
            XCTAssertFalse(usage.isComplete, malformed)
            XCTAssertEqual(QuotaPresentation.menuPercentage(usage), "—", malformed)
            XCTAssertEqual(QuotaPresentation.menuPercentage(usage, windowID: "codex.primary"), "95%", malformed)
        }
    }

    func testAbsentCodexSlotsRemainOptional() throws {
        for slots in [#""primary":{"usedPercent":5}"#, #""secondary":{"usedPercent":5}"#, #""primary":{"usedPercent":5},"secondary":null"#] {
            let usage = try SubscriptionUsage.codex(Data("{\"rateLimits\":{\(slots)}}".utf8))
            XCTAssertTrue(usage.isComplete, slots)
            XCTAssertTrue(usage.unavailableWindowIDs.isEmpty, slots)
            XCTAssertEqual(QuotaPresentation.menuPercentage(usage), "95%", slots)
        }
    }

    func testNamedBucketsNeverFallBackToOptimisticLegacyReading() throws {
        for named in [#"{"codex":{"primary":{}}}"#, #"{"codex":{}}"#, #"{"codex":null}"#] {
            let usage = try SubscriptionUsage.codex(Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":1}},\"rateLimitsByLimitId\":\(named)}".utf8))
            XCTAssertTrue(usage.windows.isEmpty, named)
            XCTAssertFalse(usage.isComplete, named)
            XCTAssertFalse(usage.unavailableWindowIDs.isEmpty, named)
            XCTAssertEqual(QuotaPresentation.menuPercentage(usage), "—", named)
        }
        let partial = try SubscriptionUsage.codex(Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":5}},"other":{}}}"#.utf8))
        XCTAssertEqual(partial.windows.map(\.usedPercent), [5])
        XCTAssertEqual(partial.unavailableWindowIDs, ["other"])
        XCTAssertEqual(QuotaPresentation.menuPercentage(partial), "—")
        let legacy = try SubscriptionUsage.codex(Data(#"{"rateLimitsByLimitId":{},"rateLimits":{"primary":{"usedPercent":5}}}"#.utf8))
        XCTAssertTrue(legacy.isComplete)
    }

    func testClaudePartialReadingsKeepKnownWindows() throws {
        for malformed in ["{}", #"{"used_percentage":null}"#, #"{"used_percentage":-1}"#, #"{"used_percentage":101}"#, #"{"used_percentage":"unknown"}"#, "null", "[]"] {
            let usage = try SubscriptionUsage.claude(Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":5},\"seven_day\":\(malformed)}}".utf8))
            XCTAssertEqual(usage.windows.map(\.usedPercent), [5], malformed)
            XCTAssertEqual(usage.unavailableWindowIDs, ["seven_day"], malformed)
            XCTAssertEqual(QuotaPresentation.menuPercentage(usage), "—", malformed)
            XCTAssertEqual(QuotaPresentation.menuPercentage(usage, windowID: "five_hour"), "95%", malformed)
        }
        let missing = try SubscriptionUsage.claude(Data(#"{"rate_limits":{"seven_day":{"used_percentage":20}}}"#.utf8))
        XCTAssertEqual(missing.unavailableWindowIDs, ["five_hour"])
        XCTAssertEqual(missing.windows.map(\.usedPercent), [20])
    }

    func testExtremeAndMalformedResetValuesDoNotDiscardValidPercentages() throws {
        for reset in ["1e30", "-1e30", "1e300", #""invalid""#, "null", "{}"] {
            let codex = try SubscriptionUsage.codex(Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":35,\"resetsAt\":\(reset)}}}".utf8))
            let claude = try SubscriptionUsage.claude(Data("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":35,\"resets_at\":\(reset)},\"seven_day\":{\"used_percentage\":20}}}".utf8))
            for usage in [codex, claude] {
                XCTAssertEqual(usage.windows.first?.usedPercent, 35, reset)
                XCTAssertNil(usage.windows.first?.resetsAt, reset)
                XCTAssertTrue(usage.isComplete, reset)
                XCTAssertEqual(QuotaPresentation.countdown(usage.windows[0], observedAt: usage.observedAt, now: usage.observedAt), "Reset time unavailable", reset)
            }
        }
    }
}
