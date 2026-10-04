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

        // Verify the actual macOS deletion API against one owned store, seeded offline.
        let identifier = UUID()
        do {
            var seededStore: WKWebsiteDataStore? = WKWebsiteDataStore(forIdentifier: identifier)
            await seedSyntheticCookie(in: seededStore!)
            let seeded = await hasSyntheticCookie(in: seededStore!)
            guard seeded else { throw RegressionFailure.assertion("Synthetic cookie seed was not available") }
            seededStore = nil
            let ownedClient = ClaudeWebsiteClient(dataStoreIdentifier: identifier)
            try await ownedClient.disconnect()
            assert(!ownedClient.sessionDeletionRequired)
            let retained = await hasSyntheticCookie(in: WKWebsiteDataStore(forIdentifier: identifier))
            guard !retained else { throw RegressionFailure.assertion("Owned session cookie survived deletion") }
            // Reading the fresh store recreated it; remove that empty test store too.
            try await ClaudeWebsiteClient.removePersistentStore(identifier)
        } catch {
            try? await ClaudeWebsiteClient.removePersistentStore(identifier)
            throw error
        }
        print("PASS: shared async deletion, reconnect guard, failure/retry, stale reading epochs, owned synthetic cookie removal")
    }

    @MainActor
    private static func seedSyntheticCookie(in store: WKWebsiteDataStore) async {
        let cookie = HTTPCookie(properties: [.domain: "example.invalid", .path: "/",
                                           .name: "headroom-regression", .value: "synthetic-only",
                                           .secure: "TRUE", .expires: Date().addingTimeInterval(3600)])!
        await withCheckedContinuation { continuation in
            store.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    @MainActor
    private static func hasSyntheticCookie(in store: WKWebsiteDataStore) async -> Bool {
        return await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.contains { $0.name == "headroom-regression" })
            }
        }
    }
}
