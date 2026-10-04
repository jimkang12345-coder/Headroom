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
        XCTAssertThrowsError(try SubscriptionUsage.claude(Data("bad".utf8)))
    }
}
