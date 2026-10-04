import XCTest
@testable import HeadroomCore

final class FixturePreferencesTests: XCTestCase {
    @MainActor
    func testFixtureAccountVerificationAndRefreshStayOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = FixtureEnvironment.makeCoordinator(fixtureDir: directory)
        let connection = try await coordinator.addConnection(provider: .deepseek,
            userLabel: "Synthetic fixture", apiKey: "fixture-valid")
        XCTAssertTrue(coordinator.isFixtureMode)
        XCTAssertTrue(coordinator.secretStore is InMemorySecretStore)
        XCTAssertEqual(coordinator.connections.first?.lastObservation?.balance(for: "USD")?.totalBalance,
                       Decimal(string: "12.5000"))
        await coordinator.refresh(connectionId: connection.id)
        XCTAssertEqual(coordinator.connections.first?.lastObservation?.balance(for: "USD")?.totalBalance,
                       Decimal(string: "12.5000"))
    }

    @MainActor
    func testFixtureInvalidKeyNeverInventsAReading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = FixtureEnvironment.makeCoordinator(fixtureDir: directory)
        _ = try await coordinator.addConnection(provider: .deepseek,
            userLabel: "Synthetic invalid fixture", apiKey: "fixture-invalid")
        XCTAssertNil(coordinator.connections.first?.lastObservation)
        XCTAssertTrue(coordinator.observations.isEmpty)
    }

    func testFixtureDomainsDoNotShareConnectionFlagsOrAppearance() {
        let firstID = UUID(), secondID = UUID()
        let first = HeadroomPreferences.isolatedFixtureDefaults(identifier: firstID)
        let second = HeadroomPreferences.isolatedFixtureDefaults(identifier: secondID)
        defer {
            first.removePersistentDomain(forName: "org.headroom.fixture." + firstID.uuidString)
            second.removePersistentDomain(forName: "org.headroom.fixture." + secondID.uuidString)
        }
        first.set(true, forKey: "subscription.claude.connected")
        first.set(true, forKey: "subscription.claude.website")
        first.set("dark", forKey: "appearanceMode")

        XCTAssertTrue(first.bool(forKey: "subscription.claude.connected"))
        XCTAssertFalse(second.bool(forKey: "subscription.claude.connected"))
        XCTAssertFalse(second.bool(forKey: "subscription.claude.website"))
        XCTAssertNil(second.string(forKey: "appearanceMode"))
    }
}
