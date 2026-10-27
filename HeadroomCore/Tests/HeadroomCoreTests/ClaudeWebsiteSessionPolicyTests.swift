import XCTest
@testable import HeadroomCore

final class ClaudeWebsiteSessionPolicyTests: XCTestCase {
    func testAllowsOnlyExactHTTPSClaudeOrigin() {
        for value in ["https://claude.ai/settings/usage", "https://claude.ai/login", "https://CLAUDE.AI:443/settings/usage"] {
            XCTAssertTrue(ClaudeWebsiteNavigationPolicy.allows(URL(string: value)), value)
        }
        for value in [
            "http://claude.ai/settings/usage", "https://claude.ai:444/settings/usage",
            "https://claude.ai.example.com/settings/usage", "https://other.claude.ai/settings/usage",
            "https://claude.ai./settings/usage", "https://accounts.google.com/",
            "https://claude.ai@evil.example/", "https://user:password@claude.ai/",
            "file:///settings/usage", "javascript:alert(1)", "mailto:help@example.invalid", "about:blank"
        ] {
            XCTAssertFalse(ClaudeWebsiteNavigationPolicy.allows(URL(string: value)), value)
        }
        XCTAssertFalse(ClaudeWebsiteNavigationPolicy.allows(nil))
    }

    func testUsageExtractionRequiresAllowedOriginAndUsageLocation() {
        XCTAssertTrue(ClaudeWebsiteNavigationPolicy.isUsagePage(URL(string: "https://claude.ai/settings/usage")))
        XCTAssertTrue(ClaudeWebsiteNavigationPolicy.isUsagePage(URL(string: "https://claude.ai/#settings/usage")))
        XCTAssertFalse(ClaudeWebsiteNavigationPolicy.isUsagePage(URL(string: "https://claude.ai/login")))
        XCTAssertFalse(ClaudeWebsiteNavigationPolicy.isUsagePage(URL(string: "https://example.invalid/settings/usage")))
        XCTAssertFalse(ClaudeWebsiteNavigationPolicy.isUsagePage(URL(string: "https://user@claude.ai/settings/usage")))
    }

    func testPauseAndReconnectRejectOldReadings() {
        var session = ClaudeWebsiteSessionLifecycle()
        XCTAssertTrue(session.setEnabled(true))
        let originalEpoch = session.epoch
        XCTAssertTrue(session.acceptsReading(from: originalEpoch))
        XCTAssertTrue(session.setEnabled(false))
        XCTAssertFalse(session.acceptsReading(from: originalEpoch))
        XCTAssertTrue(session.setEnabled(true))
        XCTAssertFalse(session.acceptsReading(from: originalEpoch))
        XCTAssertTrue(session.acceptsReading(from: session.epoch))
    }

    func testFailedDeletionBlocksReconnectionUntilSuccessfulRetry() {
        var session = ClaudeWebsiteSessionLifecycle()
        session.setEnabled(true)
        let oldEpoch = session.epoch
        session.beginDeletion()
        XCTAssertFalse(session.enabled)
        XCTAssertFalse(session.setEnabled(true))
        XCTAssertFalse(session.acceptsReading(from: oldEpoch))
        session.finishDeletion(succeeded: false)
        XCTAssertTrue(session.deletionRequired)
        XCTAssertFalse(session.setEnabled(true))
        session.beginDeletion()
        session.finishDeletion(succeeded: true)
        XCTAssertFalse(session.deletionRequired)
        XCTAssertTrue(session.setEnabled(true))
        XCTAssertFalse(session.acceptsReading(from: oldEpoch))
        XCTAssertTrue(session.acceptsReading(from: session.epoch))
    }

    let start = Date(timeIntervalSince1970: 2000000000)
    private func next(_ schedule: inout ClaudeWebsiteRefreshSchedule, _ offset: TimeInterval, loading: Bool = false,
                      usagePage: Bool = true, signingIn: Bool = false, watched: Bool = true,
                      forced: Bool = false) -> ClaudeWebsiteRefreshSchedule.Step {
        schedule.next(at: start.addingTimeInterval(offset), isLoading: loading, onUsagePage: usagePage,
                      signingIn: signingIn, watched: watched, forced: forced)
    }

    func testSuccessfulReadSchedulesNextReload() {
        var schedule = ClaudeWebsiteRefreshSchedule()
        XCTAssertEqual(next(&schedule, 0, usagePage: false), .reload)
        schedule.beginLoad(at: start)
        XCTAssertEqual(next(&schedule, 1, loading: true), .wait)
        schedule.finishLoad(onUsagePage: true, signingIn: false, at: start.addingTimeInterval(2))
        XCTAssertEqual(next(&schedule, 2), .read)
        schedule.beginRead(at: start.addingTimeInterval(2))
        XCTAssertEqual(next(&schedule, 3), .wait)
        schedule.finishRead(succeeded: true, at: start.addingTimeInterval(3))
        XCTAssertEqual(next(&schedule, 32), .wait)
        XCTAssertEqual(next(&schedule, 33), .reload)
    }

    func testUnansweredReadDoesNotStopRefreshes() {
        // A suspended page may never answer the script. Abandon the reply, not the refresh loop.
        var schedule = ClaudeWebsiteRefreshSchedule()
        schedule.beginLoad(at: start)
        schedule.finishLoad(onUsagePage: true, signingIn: false, at: start)
        schedule.beginRead(at: start)
        XCTAssertEqual(next(&schedule, 10), .wait)
        XCTAssertEqual(next(&schedule, 11), .read)
        schedule.beginRead(at: start.addingTimeInterval(11))
        XCTAssertEqual(next(&schedule, 26), .timedOut)
        XCTAssertEqual(schedule.failures, 1)
        XCTAssertEqual(next(&schedule, 85), .wait)
        XCTAssertEqual(next(&schedule, 86), .reload)
    }

    func testUnrenderedPageTimesOutWithBackoff() {
        var schedule = ClaudeWebsiteRefreshSchedule()
        var offset: TimeInterval = 0
        for delay in [60.0, 120, 240, 300, 300] {
            XCTAssertEqual(next(&schedule, offset), .reload)
            schedule.beginLoad(at: start.addingTimeInterval(offset))
            schedule.finishLoad(onUsagePage: true, signingIn: false, at: start.addingTimeInterval(offset))
            XCTAssertEqual(next(&schedule, offset + 1), .read)
            schedule.beginRead(at: start.addingTimeInterval(offset + 1))
            schedule.finishRead(succeeded: false, at: start.addingTimeInterval(offset + 1))
            XCTAssertEqual(next(&schedule, offset + 2), .read)
            XCTAssertEqual(next(&schedule, offset + 26), .timedOut)
            XCTAssertEqual(schedule.nextLoad.timeIntervalSince(start.addingTimeInterval(offset + 26)), delay)
            offset = schedule.nextLoad.timeIntervalSince(start)
        }
    }

    func testOffscreenRedirectAwayFromUsageIsRetried() {
        // claude.ai can redirect or route away from the usage page. Unless someone can see
        // the connection window, that page is replaced on the failure schedule.
        var schedule = ClaudeWebsiteRefreshSchedule()
        schedule.beginLoad(at: start)
        schedule.finishLoad(onUsagePage: false, signingIn: false, at: start)
        XCTAssertEqual(schedule.failures, 1)
        XCTAssertEqual(next(&schedule, 59, usagePage: false), .wait)
        XCTAssertEqual(next(&schedule, 60, usagePage: false), .reload)

        schedule.beginLoad(at: start.addingTimeInterval(60))
        schedule.finishLoad(onUsagePage: true, signingIn: false, at: start.addingTimeInterval(61))
        XCTAssertEqual(next(&schedule, 70, usagePage: false), .wait)
        XCTAssertEqual(next(&schedule, 87, usagePage: false), .timedOut)
    }

    func testHiddenReadingsRepeatEveryTwoMinutes() {
        var schedule = ClaudeWebsiteRefreshSchedule()
        schedule.beginLoad(at: start)
        schedule.finishLoad(onUsagePage: true, signingIn: false, at: start)
        schedule.beginRead(at: start)
        schedule.finishRead(succeeded: true, at: start)
        XCTAssertEqual(next(&schedule, 30, watched: false), .wait)
        XCTAssertEqual(next(&schedule, 119, watched: false), .wait)
        XCTAssertEqual(next(&schedule, 120, watched: false), .reload)
        // A window coming on screen restores the faster cadence at once.
        XCTAssertEqual(next(&schedule, 30, watched: true), .reload)
        XCTAssertEqual(next(&schedule, 29, watched: true), .wait)
        // Failure backoff is never shortened by the cadence.
        schedule.fail(at: start.addingTimeInterval(120))
        XCTAssertEqual(next(&schedule, 179, watched: true), .wait)
        XCTAssertEqual(next(&schedule, 180, watched: false), .reload)
    }

    func testVisibleSignInFormIsNotReloaded() {
        var schedule = ClaudeWebsiteRefreshSchedule()
        schedule.beginLoad(at: start)
        schedule.finishLoad(onUsagePage: false, signingIn: true, at: start)
        XCTAssertEqual(schedule.failures, 0)
        XCTAssertEqual(next(&schedule, 600, usagePage: false, signingIn: true), .wait)
        XCTAssertEqual(next(&schedule, 600, usagePage: true, signingIn: true), .reload)
    }

    func testForcedRefreshThrottleAndResume() {
        var schedule = ClaudeWebsiteRefreshSchedule()
        schedule.beginLoad(at: start)
        schedule.finishLoad(onUsagePage: true, signingIn: false, at: start)
        schedule.beginRead(at: start)
        schedule.finishRead(succeeded: true, at: start)
        XCTAssertEqual(next(&schedule, 4, forced: true), .wait)
        XCTAssertEqual(next(&schedule, 5, forced: true), .reload)

        schedule.beginLoad(at: start.addingTimeInterval(5))
        schedule.pause()
        schedule.resume()
        XCTAssertEqual(next(&schedule, 6, loading: true, watched: false), .reload)
        schedule.fail(at: start.addingTimeInterval(6))
        XCTAssertEqual(next(&schedule, 7), .wait)
    }
}
