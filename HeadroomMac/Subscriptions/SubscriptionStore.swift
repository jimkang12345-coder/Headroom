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
    struct ExtraClaudeAccount: Identifiable {
        let id: String
        let label: String
        var connected: Bool
        var usage: SubscriptionUsage?
        var message: String?
    }
    @Published private(set) var extraClaude: [ExtraClaudeAccount] = []
    @Published private(set) var grokSpend: GrokSpend?
    @Published private(set) var grokConnected = false
    @Published private(set) var hermesLabel: String?
    @Published private(set) var codexLabel = "Codex"
    @Published private(set) var claudeLabel = "Claude Code"
    /// True after a direct Claude account reading fills the primary limits.
    @Published private(set) var claudeAccountLimits = false
    private var extraFeeds: [String: ClaudeUsageFeed] = [:]
    private var extraTimestamps: [String: Date] = [:]
    private var nextGrokRefresh = Date.distantPast
    private var nextClaudeOAuth = Date.distantPast
    private var claudeOAuthInFlight = false
    private var claudeOAuthAgain = false
    private var codexHome: URL?
    private let connectedExtraKey = "subscription.claude.extra.connected"
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
    private var launchAccountsConnected = false

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
        loadLocalAccounts()
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
            self.readExtraClaude()
            self.maybeRefreshGrok()
            self.maybeRefreshClaudeOAuth()
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
            claudeAccountLimits = false
        } else {
            isSyntheticMode = false
            codex = nil; claude = nil
            claudeAccountLimits = false
            setSuspended(false)
        }
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        claudeWebsite.setEnabled(claudeUsesWebsite && !value && !sleeping)
        generation += 1
        if value { codex = nil; claude = nil; lastClaudeTimestamp = nil; claudeAccountLimits = false }
        else {
            schedule.resume()
            Task { await refresh() }
            // The view task can run while this store is still paused at launch and return
            // without connecting. Run the one-shot request only after tracking is live.
            guard !launchAccountsConnected,
                  ProcessInfo.processInfo.arguments.contains("--connect-local-accounts") else { return }
            launchAccountsConnected = true
            Task { await connectDiscovered() }
        }
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
        claudeAccountLimits = false
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
        readExtraClaude()
        maybeRefreshGrok(force: true)
        maybeRefreshClaudeOAuth(force: forced)
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
                let home = self.codexHome
                let usage = try await Task.detached { try CodexUsageClient.read(codexHome: home) }.value
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
        if isClaude {
            if claudeUsesWebsite { return "Checked Claude account usage" }
            if claudeAccountLimits { return "Checked Claude account limits" }
            return "Claude Code feed received"
        }
        return "Checked with Codex"
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
                noteClaudeWaiting("Reading Claude account limits…")
                return
            }
            let feedURL = claudeFeed.feed
            guard FileManager.default.fileExists(atPath: feedURL.path) else {
                noteClaudeWaiting("Reading Claude account limits…")
                return
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: feedURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65_536 else { throw UsageError.message("Claude’s feed is too large.") }
            let timestamp = attributes[.modificationDate] as? Date ?? .distantPast
            guard timestamp != lastClaudeTimestamp else { return }
            let usage = try SubscriptionUsage.claude(Data(contentsOf: feedURL), now: timestamp)
            lastClaudeTimestamp = timestamp
            // An empty status line must not replace account-limit bars.
            guard !usage.windows.isEmpty else {
                noteClaudeWaiting("Reading Claude account limits…")
                return
            }
            claude = usage
            claudeAccountLimits = false
            claudeMessage = nil
        } catch { noteClaudeWaiting(error.localizedDescription) }
    }

    private func noteClaudeWaiting(_ message: String) {
        guard claude?.windows.isEmpty != false else { return }
        claudeMessage = message
    }

    func connectDiscovered() async {
        guard !suspended else { return }
        let accounts = localAccounts()
        if let codex = accounts.first(where: { $0.kind == .codex }) {
            codexHome = codex.homePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            codexLabel = codex.label
        }
        let claudeHomes = accounts.filter { $0.kind == .claude }
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL.path
        for account in claudeHomes where account.homePath != defaultHome {
            connectExtra(account)
        }
        grokConnected = accounts.contains { $0.kind == .grok }
        defaults.set(grokConnected, forKey: "subscription.grok.connected")
        maybeRefreshGrok(force: true)
        // Codex's rate-limit RPC can take the full timeout. Read Claude limits before that wait.
        if claudeHomes.contains(where: { $0.homePath == defaultHome }), !claudeConnected || claudeUsesWebsite {
            await connectClaude()
        }
        maybeRefreshClaudeOAuth(force: true)
        if accounts.contains(where: { $0.kind == .codex }) {
            await connectCodex()
        }
    }

    private func loadLocalAccounts() {
        let accounts = localAccounts()
        let defaultHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").standardizedFileURL.path
        if let codex = accounts.first(where: { $0.kind == .codex }) {
            codexHome = codex.homePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            codexLabel = codex.label
        }
        if let primary = accounts.first(where: { $0.kind == .claude && $0.homePath == defaultHome }) {
            claudeLabel = primary.label
        }
        hermesLabel = accounts.first { $0.kind == .hermes }?.label
        grokConnected = accounts.contains { $0.kind == .grok }
        let saved = Set(defaults.stringArray(forKey: connectedExtraKey) ?? [])
        extraClaude = accounts.filter { $0.kind == .claude && $0.homePath != defaultHome }.map { account in
            let path = account.homePath ?? account.id
            extraFeeds[path] = feed(for: path)
            return ExtraClaudeAccount(id: path, label: account.label, connected: saved.contains(path), usage: nil, message: nil)
        }
    }

    private func localAccounts() -> [LocalCodingAccount] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settings = home.appendingPathComponent(".t3/userdata/settings.json")
        let data = try? Data(contentsOf: settings)
        return LocalUsageCatalog.accounts(t3Settings: data, home: home)
    }

    private func feed(for configPath: String) -> ClaudeUsageFeed {
        let digest = configPath.utf8.reduce(UInt64(5381)) { ($0 &<< 5) &+ $0 &+ UInt64($1) }
        let storage = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Headroom/Subscriptions/accounts/\(String(digest, radix: 16))", isDirectory: true)
        return ClaudeUsageFeed(settings: URL(fileURLWithPath: configPath).appendingPathComponent("settings.json"), directory: storage)
    }

    private func connectExtra(_ account: LocalCodingAccount) {
        guard let path = account.homePath else { return }
        let installed = extraFeeds[path] ?? feed(for: path)
        extraFeeds[path] = installed
        do {
            try installed.install()
            updateExtra(path) { account in
                account.connected = true
                account.message = nil
            }
            var saved = Set(defaults.stringArray(forKey: connectedExtraKey) ?? [])
            saved.insert(path)
            defaults.set(Array(saved), forKey: connectedExtraKey)
            readExtraClaude()
        } catch {
            updateExtra(path) { $0.message = error.localizedDescription }
        }
    }

    private func readExtraClaude() {
        for index in extraClaude.indices where extraClaude[index].connected {
            let id = extraClaude[index].id
            guard let installed = extraFeeds[id] else { continue }
            do {
                guard installed.isInstalled else {
                    noteExtraWaiting(id, "Reading this Claude account’s limits…")
                    continue
                }
                let feedURL = installed.feed
                guard FileManager.default.fileExists(atPath: feedURL.path) else {
                    noteExtraWaiting(id, "Reading this Claude account’s limits…")
                    continue
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: feedURL.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65_536 else { throw UsageError.message("Claude’s feed is too large.") }
                let timestamp = attributes[.modificationDate] as? Date ?? .distantPast
                guard timestamp != extraTimestamps[id] else { continue }
                let usage = try SubscriptionUsage.claude(Data(contentsOf: feedURL), now: timestamp)
                extraTimestamps[id] = timestamp
                guard !usage.windows.isEmpty else {
                    noteExtraWaiting(id, "Reading this Claude account’s limits…")
                    continue
                }
                updateExtra(id) {
                    $0.usage = usage
                    $0.message = nil
                }
            } catch {
                noteExtraWaiting(id, error.localizedDescription)
            }
        }
    }

    private func noteExtraWaiting(_ id: String, _ message: String) {
        guard extraClaude.first(where: { $0.id == id })?.usage?.windows.isEmpty != false else { return }
        updateExtra(id) { $0.message = message }
    }

    private func updateExtra(_ id: String, _ change: (inout ExtraClaudeAccount) -> Void) {
        guard let index = extraClaude.firstIndex(where: { $0.id == id }) else { return }
        var account = extraClaude[index]
        change(&account)
        extraClaude[index] = account
    }

    private func maybeRefreshClaudeOAuth(force: Bool = false) {
        guard !suspended, !sleeping, !isSyntheticMode else { return }
        let now = Date()
        guard force || now >= nextClaudeOAuth else { return }
        if claudeOAuthInFlight {
            if force { claudeOAuthAgain = true }
            return
        }
        var targets: [ClaudeOAuthTarget] = []
        if claudeConnected && !claudeUsesWebsite {
            let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
            targets.append(ClaudeOAuthTarget(id: home.standardizedFileURL.path, directory: home, primary: true))
        }
        for account in extraClaude where account.connected {
            targets.append(ClaudeOAuthTarget(id: account.id, directory: URL(fileURLWithPath: account.id, isDirectory: true), primary: false))
        }
        guard !targets.isEmpty else { return }
        nextClaudeOAuth = now.addingTimeInterval(60)
        claudeOAuthInFlight = true
        let requestGeneration = generation
        Task.detached { [weak self] in
            var readings: [ClaudeOAuthReading] = []
            for target in targets {
                do {
                    let usage = try await ClaudeAccountUsageClient.read(configDirectory: target.directory)
                    readings.append(ClaudeOAuthReading(id: target.id, primary: target.primary, usage: usage, message: nil))
                } catch {
                    let text = (error as? LocalizedError)?.errorDescription ?? "Claude account limits could not be read."
                    readings.append(ClaudeOAuthReading(id: target.id, primary: target.primary, usage: nil, message: text))
                }
            }
            await self?.applyClaudeOAuth(readings, generation: requestGeneration)
        }
    }

    private func applyClaudeOAuth(_ readings: [ClaudeOAuthReading], generation requestGeneration: Int) {
        claudeOAuthInFlight = false
        let again = claudeOAuthAgain
        claudeOAuthAgain = false
        if !suspended, !sleeping, !isSyntheticMode, generation == requestGeneration {
            for reading in readings {
                if reading.primary {
                    guard claudeConnected, !claudeUsesWebsite else { continue }
                    if let usage = reading.usage, !usage.windows.isEmpty {
                        claude = usage
                        claudeMessage = nil
                        claudeAccountLimits = true
                    } else if claude?.windows.isEmpty != false {
                        claudeMessage = reading.message ?? "Claude has not reported usable subscription limits yet."
                    }
                } else {
                    guard extraClaude.contains(where: { $0.id == reading.id && $0.connected }) else { continue }
                    if let usage = reading.usage, !usage.windows.isEmpty {
                        updateExtra(reading.id) {
                            $0.usage = usage
                            $0.message = nil
                        }
                    } else if extraClaude.first(where: { $0.id == reading.id })?.usage?.windows.isEmpty != false {
                        updateExtra(reading.id) {
                            $0.message = reading.message ?? "This Claude account has not reported usable limits yet."
                        }
                    }
                }
            }
        }
        if again { maybeRefreshClaudeOAuth(force: true) }
    }

    private func maybeRefreshGrok(force: Bool = false) {
        guard grokConnected, !suspended else { return }
        let now = Date()
        guard force || now >= nextGrokRefresh else { return }
        nextGrokRefresh = now.addingTimeInterval(30)
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok/sessions", isDirectory: true)
        Task.detached { [weak self] in
            let files = Self.grokUsageFiles(in: root)
            let spend = GrokSpend.summarize(files, now: Date())
            await self?.applyGrok(spend)
        }
    }

    private func applyGrok(_ spend: GrokSpend) {
        grokSpend = spend
    }

    nonisolated private static func grokUsageFiles(in root: URL) -> [Data] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [Data] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "usage.json", files.count < 500 else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= 2_000_000, let data = try? Data(contentsOf: url) else { continue }
            files.append(data)
        }
        return files
    }
}

private struct ClaudeOAuthTarget: Sendable {
    let id: String
    let directory: URL
    let primary: Bool
}

private struct ClaudeOAuthReading: Sendable {
    let id: String
    let primary: Bool
    let usage: SubscriptionUsage?
    let message: String?
}
