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
