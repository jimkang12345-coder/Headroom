import Foundation
import WebKit
import HeadroomCore

enum SyntheticFailure: Error { case deletion }
enum RegressionFailure: Error { case assertion(String) }

@MainActor
final class ControlledRemoval {
    var calls = 0
    private var pending: CheckedContinuation<Void, Error>?

    func remove(_ identifier: UUID) async throws {
        calls += 1
        try await withCheckedThrowingContinuation { pending = $0 }
    }

    func waitUntilPending() async {
        while pending == nil { await Task.yield() }
    }

    func finish(succeeded: Bool) {
        let continuation = pending!
        pending = nil
        if succeeded { continuation.resume() }
        else { continuation.resume(throwing: SyntheticFailure.deletion) }
    }
}

@main
struct WebsiteSessionRegression {
    @MainActor
    static func main() async throws {
        // All clients use owned random UUIDs. No browser/window or remote request is created.
        let controlled = ControlledRemoval()
        let client = ClaudeWebsiteClient(dataStoreIdentifier: UUID(), removeDataStore: controlled.remove)
        let first = Task { try await client.disconnect() }
        await controlled.waitUntilPending()
        assert(client.isDeletingSession && client.sessionDeletionRequired && !client.enabled)
        client.setEnabled(true)
        assert(!client.enabled)
        let second = Task { try await client.disconnect() }
        await Task.yield()
        assert(controlled.calls == 1)
        controlled.finish(succeeded: false)
        for task in [first, second] {
            do { try await task.value; assertionFailure("Failure must reach every waiter") }
            catch SyntheticFailure.deletion {}
        }
        assert(!client.isDeletingSession && client.sessionDeletionRequired && !client.enabled)
        client.setEnabled(true)
        assert(!client.enabled)
        let retry = Task { try await client.disconnect() }
        await controlled.waitUntilPending()
        assert(controlled.calls == 2)
        controlled.finish(succeeded: true)
        try await retry.value
        assert(!client.isDeletingSession && !client.sessionDeletionRequired && !client.enabled)

        // A synthetic outstanding-reading token is rejected throughout reset and reconnect.
        var lifecycle = ClaudeWebsiteSessionLifecycle()
        lifecycle.setEnabled(true)
        let previous = lifecycle.epoch
        lifecycle.beginDeletion()
        assert(!lifecycle.acceptsReading(from: previous))
        lifecycle.finishDeletion(succeeded: true)
        lifecycle.setEnabled(true)
        assert(!lifecycle.acceptsReading(from: previous))
        assert(lifecycle.acceptsReading(from: lifecycle.epoch))

        // First connection and repeated disconnect must succeed without creating
        // a persistent profile. Enumeration is intentionally the first real WebKit
        // operation, covering its required in-memory initialization too.
        progress("CHECK: absent owned profile and repeated disconnect")
        let absentIdentifier = UUID()
        guard !(await ClaudeWebsiteClient.persistentStoreExists(absentIdentifier)) else {
            throw RegressionFailure.assertion("Random absent identifier unexpectedly exists")
        }
        let absentClient = ClaudeWebsiteClient(dataStoreIdentifier: absentIdentifier)
        for _ in 0..<2 {
            try await absentClient.disconnect()
            assert(!absentClient.sessionDeletionRequired && !absentClient.isDeletingSession)
            guard !(await ClaudeWebsiteClient.persistentStoreExists(absentIdentifier)) else {
                throw RegressionFailure.assertion("Absent-profile cleanup created a persistent profile")
            }
        }

        // Verify the actual macOS deletion API against one owned store, seeded offline.
        let identifier = UUID()
        var phase = "seed owned synthetic cookie"
        do {
            progress("CHECK: \(phase)")
            var seededStore: WKWebsiteDataStore? = WKWebsiteDataStore(forIdentifier: identifier)
            await seedSyntheticCookie(in: seededStore!)
            let seeded = await hasSyntheticCookie(in: seededStore!)
            guard seeded else { throw RegressionFailure.assertion("Synthetic cookie seed was not available") }
            guard await ClaudeWebsiteClient.persistentStoreExists(identifier) else {
                throw RegressionFailure.assertion("Seeded website profile was not registered on disk")
            }
            seededStore = nil
            phase = "delete registered owned profile"
            progress("CHECK: \(phase)")
            let ownedClient = ClaudeWebsiteClient(dataStoreIdentifier: identifier)
            try await ownedClient.disconnect()
            assert(!ownedClient.sessionDeletionRequired)
            guard !(await ClaudeWebsiteClient.persistentStoreExists(identifier)) else {
                throw RegressionFailure.assertion("Owned website profile survived deletion")
            }
            phase = "verify synthetic cookie absence in reopened profile"
            progress("CHECK: \(phase)")
            var verificationStore: WKWebsiteDataStore? = WKWebsiteDataStore(forIdentifier: identifier)
            let retained = await hasSyntheticCookie(in: verificationStore!)
            guard !retained else { throw RegressionFailure.assertion("Owned session cookie survived deletion") }
            // An empty read can expose a transient profile directory on macOS 15.
            // Materialize a different synthetic cookie before releasing this store,
            // matching the registered, seeded lifecycle verified by the first delete.
            // The original cookie's absence has already been asserted above.
            phase = "materialize reopened owned profile for cleanup"
            progress("CHECK: \(phase)")
            let cleanupCookieName = "headroom-cleanup-regression"
            await seedSyntheticCookie(in: verificationStore!, name: cleanupCookieName)
            guard await hasSyntheticCookie(in: verificationStore!, name: cleanupCookieName) else {
                throw RegressionFailure.assertion("Fresh synthetic cleanup cookie was not available")
            }
            guard await ClaudeWebsiteClient.persistentStoreExists(identifier) else {
                throw RegressionFailure.assertion("Reopened seeded website profile was not registered on disk")
            }
            verificationStore = nil
            phase = "clean up reopened owned profile"
            progress("CHECK: \(phase)")
            try await ClaudeWebsiteClient.removePersistentStore(identifier)
            guard !(await ClaudeWebsiteClient.persistentStoreExists(identifier)) else {
                throw RegressionFailure.assertion("Reopened owned test profile survived cleanup")
            }
        } catch {
            diagnostic("FAIL: \(phase)", error: error)
            do { try await ClaudeWebsiteClient.removePersistentStore(identifier) }
            catch { diagnostic("FAIL: owned test profile cleanup after failure", error: error) }
            throw error
        }
        progress("PASS: shared async deletion, reconnect guard, failure/retry, stale reading epochs, absent/repeated cleanup, registered owned profile and synthetic cookie removal")
    }

    private static func progress(_ text: String) {
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }

    private static func diagnostic(_ phase: String, error: Error) {
        let value = error as NSError
        // Include the failing phase and error category, without identifiers, paths,
        // cookies or arbitrary WebKit userInfo payloads in hosted test logs.
        FileHandle.standardError.write(Data("\(phase) (\(value.domain), code \(value.code))\n".utf8))
    }

    @MainActor
    private static func seedSyntheticCookie(in store: WKWebsiteDataStore, name: String = "headroom-regression") async {
        let cookie = HTTPCookie(properties: [.domain: "example.invalid", .path: "/",
                                           .name: name, .value: "synthetic-only",
                                           .secure: "TRUE", .expires: Date().addingTimeInterval(3600)])!
        await withCheckedContinuation { continuation in
            store.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    @MainActor
    private static func hasSyntheticCookie(in store: WKWebsiteDataStore, name: String = "headroom-regression") async -> Bool {
        return await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.contains { $0.name == name })
            }
        }
    }
}
