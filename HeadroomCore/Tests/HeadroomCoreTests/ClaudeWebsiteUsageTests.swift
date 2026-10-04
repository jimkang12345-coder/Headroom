import XCTest
@testable import HeadroomCore

final class ClaudeWebsiteUsageTests: XCTestCase {
    func testReadsAccountWindowsNotProductShareOrCredits() throws {
        let usage = try SubscriptionUsage.claudeWebsite("""
        Your usage
        Pro
        Fresh week. 8% of your weekly limit used.
        Current session
        Resets at 11:50 AM
        51% used
        This week
        Resets Monday 11:00 AM
        8% used
        Usage credits
        50% used
        This week’s usage by product
        Claude Code
        93%
        """)
        XCTAssertEqual(usage.windows.map(\.usedPercent), [51, 8])
        XCTAssertEqual(usage.windows[0].resetText, "Resets at 11:50 AM")
        XCTAssertNil(usage.windows[0].resetsAt)
    }
    func testMissingSessionKeepsReportedWeeklyLimit() throws {
        let usage = try SubscriptionUsage.claudeWebsite("Your usage\nCurrent session\nThis week\n8% used")
        XCTAssertEqual(usage.windows.map(\.id), ["seven_day"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [8])
    }
    func testMissingWeeklyLimitKeepsReportedSession() throws {
        let usage = try SubscriptionUsage.claudeWebsite("Your usage\nCurrent session\nResets at 10:40 PM\n35% used\nThis week\nUsage credits\n90% used")
        XCTAssertEqual(usage.windows.map(\.id), ["five_hour"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [35])
    }
    func testLoginAndUnsupportedLayoutFailClosed() {
        for text in ["Sign in to Claude", "Your usage\nCurrent session\n150% used\nThis week\n180% used", "Your usage\nCurrent session\n51%\nThis week\n8%"] {
            XCTAssertThrowsError(try SubscriptionUsage.claudeWebsite(text))
        }
    }
}
