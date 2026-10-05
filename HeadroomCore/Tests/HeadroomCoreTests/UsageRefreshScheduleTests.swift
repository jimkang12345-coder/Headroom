import XCTest
@testable import HeadroomCore

final class UsageRefreshScheduleTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 2000000000)
    func testCadenceAndNoOverlap() {
        var schedule = UsageRefreshSchedule()
        XCTAssertTrue(schedule.begin(at: start))
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(20), forced: true))
        schedule.finish(at: start.addingTimeInterval(1), succeeded: true)
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(59)))
        XCTAssertTrue(schedule.begin(at: start.addingTimeInterval(60)))
    }
    func testBackoffAndRecovery() {
        var schedule = UsageRefreshSchedule()
        var now = start
        for delay in [60.0, 120, 240, 300, 300, 300] {
            XCTAssertTrue(schedule.begin(at: now))
            schedule.finish(at: now, succeeded: false)
            XCTAssertEqual(schedule.nextAttempt.timeIntervalSince(now), delay)
            XCTAssertFalse(schedule.begin(at: now.addingTimeInterval(delay - 1)))
            now = schedule.nextAttempt
        }
        XCTAssertTrue(schedule.begin(at: now))
        schedule.finish(at: now, succeeded: true)
        XCTAssertEqual(schedule.failures, 0)
        XCTAssertEqual(schedule.nextAttempt.timeIntervalSince(now), 60)
    }
    func testManualThrottleAndWake() {
        var schedule = UsageRefreshSchedule()
        XCTAssertTrue(schedule.begin(at: start))
        schedule.finish(at: start, succeeded: false)
        XCTAssertFalse(schedule.begin(at: start.addingTimeInterval(2), forced: true))
        XCTAssertTrue(schedule.begin(at: start.addingTimeInterval(3), forced: true))
        schedule.finish(at: start.addingTimeInterval(4), succeeded: false)
        schedule.resume()
        XCTAssertTrue(schedule.begin(at: start.addingTimeInterval(10)))
    }
}
