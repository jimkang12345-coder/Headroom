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
}
