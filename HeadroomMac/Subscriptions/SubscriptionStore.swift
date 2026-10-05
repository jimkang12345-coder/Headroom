import Foundation
import Combine
import AppKit
import HeadroomCore

@MainActor
final class SubscriptionStore: ObservableObject {
    @Published private(set) var isSyntheticMode = false
    @Published var codex: SubscriptionUsage?
    @Published var claude: SubscriptionUsage?
    @Published var codexMessage: String?
    @Published var claudeMessage: String?
    @Published var refreshing = false
    @Published private(set) var displayTime = Date()
    @Published private(set) var codexConnected: Bool
    @Published private(set) var claudeConnected: Bool
    @Published private(set) var claudeUsesWebsite: Bool
    @Published private(set) var claudeDisconnecting = false
    @Published private(set) var claudeDisconnectFailed = false
    private let defaults = HeadroomPreferences.defaults
    private let claudeFeed = ClaudeUsageFeed()
    private let claudeWebsite = ClaudeWebsiteClient()
    private var generation = 0
    private var suspended = true
    var connectionsPaused: Bool { suspended }
    private var timer: AnyCancellable?
    private var lifecycle = Set<AnyCancellable>()
    private var schedule = UsageRefreshSchedule()
    private var sleeping = false
    private var lastClaudeTimestamp: Date?

    init() {
        codexConnected = HeadroomPreferences.defaults.bool(forKey: "subscription.codex.connected")
        claudeConnected = HeadroomPreferences.defaults.bool(forKey: "subscription.claude.connected")
        claudeUsesWebsite = HeadroomPreferences.defaults.bool(forKey: "subscription.claude.website")
        claudeDisconnectFailed = HeadroomPreferences.defaults.bool(forKey: "subscription.claude.cleanupRequired")
        if claudeDisconnectFailed {
            claudeConnected = false
            claudeUsesWebsite = false
            claudeMessage = "Finish deleting Headroom’s previous local Claude session before reconnecting."
        }
        claudeWebsite.onUsage = { [weak self] usage in
            guard let self, !self.suspended, !self.sleeping, self.claudeConnected,
                  self.claudeUsesWebsite, !self.claudeDisconnecting, !self.claudeDisconnectFailed else { return }
            self.claude = usage
            self.claudeMessage = nil
        }
        claudeWebsite.onStatus = { [weak self] message in self?.claudeMessage = message }
        timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self else { return }
            if self.isSyntheticMode { self.displayTime = Date(); return }
            guard !self.suspended, !self.sleeping else { return }
            self.displayTime = Date()
            // Feed ingestion must not wait on a slow Codex network request.
            if self.claudeConnected && !self.claudeUsesWebsite { self.readClaude() }
            if self.claudeUsesWebsite { self.claudeWebsite.tick() }
            Task { await self.refresh(forced: false) }
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                self?.sleeping = true
                self?.claudeWebsite.setEnabled(false)
                self?.generation += 1
            }.store(in: &lifecycle)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.sleeping = false
                self.claudeWebsite.setEnabled(self.claudeUsesWebsite && !self.suspended)
                self.schedule.resume()
                Task { await self.refresh(forced: false) }
            }.store(in: &lifecycle)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                Task { await self?.refresh() }
            }.store(in: &lifecycle)
    }
    func setSyntheticMode(_ enabled: Bool) {
        guard isSyntheticMode != enabled else {
            if !enabled { setSuspended(false) }
            return
        }
        if enabled {
            setSuspended(true)
            isSyntheticMode = true
            let anchor = Date()
            displayTime = anchor
            codex = SubscriptionFixtures.codex(at: anchor)
            claude = SubscriptionFixtures.claudeCode(at: anchor)
            codexMessage = nil
            claudeMessage = nil
        } else {
            isSyntheticMode = false
            codex = nil; claude = nil
            setSuspended(false)
        }
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        claudeWebsite.setEnabled(claudeUsesWebsite && !value && !sleeping)
        generation += 1
        if value { codex = nil; claude = nil; lastClaudeTimestamp = nil }
        else { schedule.resume(); Task { await refresh() } }
    }
    func connectCodex() async {
        guard !suspended else { return }
        codexConnected = true
        defaults.set(true, forKey: "subscription.codex.connected")
        await refresh()
    }
    func disconnectCodex() {
        guard !suspended else { return }
        generation += 1
        codexConnected = false
        defaults.set(false, forKey: "subscription.codex.connected")
        codex = nil
        codexMessage = nil
    }
    func connectClaudeWebsite() async {
        guard !suspended, !claudeDisconnecting, !claudeDisconnectFailed else { return }
        if claudeConnected && !claudeUsesWebsite {
            guard await disconnectClaude() else { return }
        }
        guard !suspended else { return }
        if !claudeUsesWebsite { claude = nil }
        claudeUsesWebsite = true
        claudeConnected = true
        defaults.set(true, forKey: "subscription.claude.website")
        defaults.set(true, forKey: "subscription.claude.connected")
        claudeWebsite.showConnection()
    }
    func connectClaude() async {
        guard !suspended, !claudeDisconnecting, !claudeDisconnectFailed else { return }
        // Switching away from website usage also removes its saved sign-in session.
        guard await disconnectClaude(), !suspended else { return }
        do {
            try claudeFeed.install()
            claudeUsesWebsite = false
            defaults.set(false, forKey: "subscription.claude.website")
            claudeWebsite.setEnabled(false)
            lastClaudeTimestamp = nil
            claudeConnected = true
            defaults.set(true, forKey: "subscription.claude.connected")
            readClaude()
        } catch { claudeMessage = error.localizedDescription }
    }
    @discardableResult
    func disconnectClaude() async -> Bool {
        guard !suspended, !claudeDisconnecting else { return false }
        let hadCodeConnection = claudeConnected && !claudeUsesWebsite
        claudeDisconnecting = true
        claudeDisconnectFailed = false
        // A quit or failed deletion must not reopen the retained session on next launch.
        defaults.set(true, forKey: "subscription.claude.cleanupRequired")
        defer { claudeDisconnecting = false }
        claudeWebsite.setEnabled(false)
        claudeUsesWebsite = false
        defaults.set(false, forKey: "subscription.claude.website")
        lastClaudeTimestamp = nil
        claudeConnected = false
        defaults.set(false, forKey: "subscription.claude.connected")
        claude = nil
        claudeMessage = "Deleting Headroom’s local Claude sign-in session…"
        var feedCleanupFailed = false
        do {
            // Remove only Headroom's owned wrapper; preserve independently changed settings.
            if hadCodeConnection || claudeFeed.needsCleanup {
                try claudeFeed.uninstall()
            }
        } catch { feedCleanupFailed = true }
        do {
            try await claudeWebsite.disconnect()
            claudeDisconnectFailed = feedCleanupFailed
            claudeMessage = feedCleanupFailed ? "Disconnected, but the Claude Code feed could not be removed. Retry cleanup before reconnecting." : nil
        } catch {
            claudeDisconnectFailed = true
            claudeMessage = "Disconnected, but the saved Claude sign-in session could not be deleted. Retry cleanup before reconnecting."
        }
        defaults.set(claudeDisconnectFailed, forKey: "subscription.claude.cleanupRequired")
        return !claudeDisconnectFailed
    }
    func refresh(forced: Bool = true) async {
        guard !suspended, !sleeping else { return }
        displayTime = Date()
        if claudeConnected && !claudeUsesWebsite { readClaude() }
        if claudeUsesWebsite { claudeWebsite.tick(force: forced) }
        if codexConnected, schedule.begin(at: Date(), forced: forced) {
            refreshing = true
            var succeeded = false
            defer {
                schedule.finish(at: Date(), succeeded: succeeded)
                refreshing = false
            }
            let requestGeneration = generation
            do {
                let usage = try await Task.detached { try CodexUsageClient.read() }.value
                guard generation == requestGeneration, codexConnected else { return }
                succeeded = true
                codex = usage
                codexMessage = usage.windows.isEmpty ? "No usable subscription limits were reported. Check that Codex is signed in with ChatGPT rather than an API key." : nil
            } catch {
                guard generation == requestGeneration, codexConnected else { return }
                codexMessage = error.localizedDescription
            }
        }
    }
    func freshness(_ usage: SubscriptionUsage, isClaude: Bool) -> String {
        if isSyntheticMode { return "Synthetic sample · no provider connection" }
        if (isClaude ? claudeMessage : codexMessage) != nil { return "Last known reading · update unavailable" }
        let age = max(0, displayTime.timeIntervalSince(usage.observedAt))
        let resetPassed = usage.windows.contains { $0.resetsAt.map { $0 <= displayTime } ?? false }
        if resetPassed { return "Reset passed · awaiting provider update" }
        if age > 120 {
            return isClaude ? (claudeUsesWebsite ? "Claude website update delayed" : "Awaiting fresh Claude Code data") : "Last known reading · refresh delayed"
        }
        if !usage.isComplete { return "Partial reading · some limits unavailable" }
        return isClaude ? (claudeUsesWebsite ? "Checked Claude account usage" : "Claude Code feed received") : "Checked with Codex"
    }

    func openClaude() {
        guard !suspended else { return }
        let candidates = [NSHomeDirectory() + "/.local/bin/claude", NSHomeDirectory() + "/.npm-global/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            claudeMessage = "Install Claude Code, then try again."
            return
        }
        do {
            let directory = ClaudeUsageFeed().directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = directory.appendingPathComponent("Open Claude Code.command")
            let escaped = executable.replacingOccurrences(of: "'", with: "'\"'\"'")
            let text = "#!/bin/bash\nexport PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\ncd \"$HOME\"\nexec '" + escaped + "'\n"
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch { claudeMessage = error.localizedDescription }
    }

    private func readClaude() {
        do {
            guard claudeFeed.isInstalled else {
                claude = nil
                claudeMessage = "Claude’s status line has changed. Disconnect and reconnect to bind the feed again."
                return
            }
            let feedURL = claudeFeed.feed
            guard FileManager.default.fileExists(atPath: feedURL.path) else {
                claudeMessage = "Awaiting Claude Code. Open a signed-in session on this Mac; limits appear when Claude emits its status line. Requires Claude Code 2.1.80 or later."
                return
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: feedURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65_536 else { throw UsageError.message("Claude’s feed is too large.") }
            let timestamp = attributes[.modificationDate] as? Date ?? .distantPast
            guard timestamp != lastClaudeTimestamp else { return }
            let usage = try SubscriptionUsage.claude(Data(contentsOf: feedURL), now: timestamp)
            lastClaudeTimestamp = timestamp
            claude = usage
            claudeMessage = usage.windows.isEmpty ? "Claude has not reported usable subscription limits yet. Use a Pro or Max session in Claude Code 2.1.80 or later. Context usage is not subscription usage." : nil
        } catch { claudeMessage = error.localizedDescription }
    }
}
