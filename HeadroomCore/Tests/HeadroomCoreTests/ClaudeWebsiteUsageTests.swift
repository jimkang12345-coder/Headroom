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
        XCTAssertTrue(usage.isComplete)
    }
    func testMissingSessionKeepsReportedWeeklyLimit() throws {
        let usage = try SubscriptionUsage.claudeWebsite("Your usage\nCurrent session\nThis week\n8% used")
        XCTAssertEqual(usage.windows.map(\.id), ["seven_day"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [8])
        XCTAssertEqual(usage.unavailableWindowIDs, ["five_hour"])
        XCTAssertEqual(QuotaPresentation.menuPercentage(usage), "—")
    }
    func testMissingWeeklyLimitKeepsReportedSession() throws {
        let usage = try SubscriptionUsage.claudeWebsite("Your usage\nCurrent session\nResets at 10:40 PM\n35% used\nThis week\nUsage credits\n90% used")
        XCTAssertEqual(usage.windows.map(\.id), ["five_hour"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [35])
        XCTAssertEqual(usage.unavailableWindowIDs, ["seven_day"])
        XCTAssertEqual(QuotaPresentation.menuPercentage(usage), "—")
    }
    func testLoginAndUnsupportedLayoutFailClosed() {
        for text in ["Sign in to Claude", "Your usage\nCurrent session\n150% used\nThis week\n180% used", "Your usage\nCurrent session\n51%\nThis week\n8%"] {
            XCTAssertThrowsError(try SubscriptionUsage.claudeWebsite(text))
        }
    }

    func testNestedWeeklyAllModelsWindowIsRead() throws {
        for heading in ["This week", "Weekly limits"] {
            let usage = try SubscriptionUsage.claudeWebsite("Your usage\nCurrent session\n5% used\n\(heading)\nAll models\nResets Monday 11:00 AM\n95% used\nSonnet only\n1% used")
            XCTAssertEqual(usage.windows.map(\.usedPercent), [5, 95])
            XCTAssertEqual(usage.windows.last?.resetText, "Resets Monday 11:00 AM")
            XCTAssertTrue(usage.isComplete)
            XCTAssertEqual(QuotaPresentation.menuPercentage(usage), "5%")
        }
    }

    func testMissingNestedWeeklyPercentageDoesNotConsumeOtherSections() throws {
        for boundary in ["Sonnet only", "Usage credits", "Extra usage", "This week’s usage by product", "This week's usage by product", "Current session"] {
            let usage = try SubscriptionUsage.claudeWebsite("Your usage\nCurrent session\n5% used\nThis week\nAll models\nResets Monday 11:00 AM\n\(boundary)\n95% used")
            XCTAssertEqual(usage.windows.map(\.usedPercent), [5], boundary)
            XCTAssertEqual(usage.unavailableWindowIDs, ["seven_day"], boundary)
            XCTAssertEqual(QuotaPresentation.menuPercentage(usage), "—", boundary)
            XCTAssertEqual(QuotaPresentation.menuPercentage(usage, windowID: "five_hour"), "95%", boundary)
        }
    }

    func testMissingSessionDoesNotConsumeNestedWeeklyPercentage() throws {
        let usage = try SubscriptionUsage.claudeWebsite("Plan usage limits\nCurrent session\nThis week\nAll models\n95% used")
        XCTAssertEqual(usage.windows.map(\.id), ["seven_day"])
        XCTAssertEqual(usage.windows.map(\.usedPercent), [95])
        XCTAssertEqual(usage.unavailableWindowIDs, ["five_hour"])
    }
}
