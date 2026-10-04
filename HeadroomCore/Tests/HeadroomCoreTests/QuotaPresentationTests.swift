import XCTest
@testable import HeadroomCore

final class QuotaPresentationTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        return calendar
    }
    let now = ISO8601DateFormatter().date(from: "2026-09-25T06:00:00Z")!
    func testExactCountdownAndExpiry() {
        let window = QuotaWindow(id: "test", title: "Weekly", usedPercent: 20, resetsAt: now.addingTimeInterval(2 * 86400 + 3 * 3600))
        XCTAssertEqual(QuotaPresentation.countdown(window, observedAt: now, now: now), "Resets in 2d 3h")
        XCTAssertEqual(QuotaPresentation.countdown(window, observedAt: now, now: now.addingTimeInterval(3 * 86400)), "Reset due · awaiting update")
    }
    func testWebsiteLocalTimesAndNoStaleRollover() {
        let session = QuotaWindow(id: "five_hour", title: "5-hour", usedPercent: 60, resetsAt: nil, resetText: "Resets at 11:50 AM")
        XCTAssertEqual(QuotaPresentation.countdown(session, observedAt: now, now: now, calendar: calendar), "Resets in ≈3h 50m")
        XCTAssertEqual(QuotaPresentation.countdown(session, observedAt: now, now: now.addingTimeInterval(5 * 3600), calendar: calendar), "Reset due · awaiting update")
        XCTAssertEqual(QuotaPresentation.countdown(session, observedAt: now.addingTimeInterval(5 * 3600), now: now.addingTimeInterval(5 * 3600), calendar: calendar), "Reset time awaiting update")
        let weekly = QuotaWindow(id: "week", title: "Weekly", usedPercent: 9, resetsAt: nil, resetText: "Resets Monday 11:00 AM")
        XCTAssertEqual(QuotaPresentation.countdown(weekly, observedAt: now, now: now, calendar: calendar), "Resets in ≈3d 3h")
    }
    func testUnknownWordingAndUnavailableQuota() {
        XCTAssertNil(QuotaPresentation.websiteReset("Unknown reset", observedAt: now))
        XCTAssertNil(QuotaPresentation.websiteReset("Resets at 25:90 PM", observedAt: now))
        XCTAssertEqual(QuotaPresentation.menuPercentage(nil), "—")
        let usage = try! SubscriptionUsage.claude(Data(#"{"rate_limits":{"five_hour":{"used_percentage":60},"seven_day":{"used_percentage":9}}}"#.utf8))
        XCTAssertEqual(QuotaPresentation.menuPercentage(usage), "40%")
    }
}
