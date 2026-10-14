import Foundation

public struct LocalCodingAccount: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case claude
        case codex
        case grok
        case hermes
    }

    public let id: String
    public let kind: Kind
    public let label: String
    /// Config directory for Claude or Codex. Nil for Grok and Hermes, which have no quota home.
    public let homePath: String?

    public init(id: String, kind: Kind, label: String, homePath: String?) {
        self.id = id
        self.kind = kind
        self.label = label
        self.homePath = homePath
    }
}

public enum LocalUsageCatalog {
    /// Accounts enabled in a T3 Code settings file. A missing file discovers the usual local homes.
    /// Homes must stay inside `boundary` (the user home). Disabled instances are omitted.
    public static func accounts(t3Settings: Data?, home: URL) -> [LocalCodingAccount] {
        let boundary = home.standardizedFileURL
        if let t3Settings, let parsed = parseT3(t3Settings, home: boundary) {
            return parsed
        }
        return fallback(home: boundary)
    }

    private static func parseT3(_ data: Data, home: URL) -> [LocalCodingAccount]? {
        guard let root = try? JSONDecoder().decode(T3File.self, from: data),
              let instances = root.providerInstances else { return nil }
        var accounts: [LocalCodingAccount] = []
        for (key, instance) in instances.sorted(by: { $0.key < $1.key }) where instance.enabled == true {
            switch instance.driver {
            case "claudeAgent":
                guard let directory = resolved(instance.config?.homePath, defaultName: ".claude", home: home) else { continue }
                accounts.append(LocalCodingAccount(id: directory.path, kind: .claude, label: label(instance.displayName, fallback: "Claude Code"), homePath: directory.path))
            case "codex":
                guard let directory = resolved(instance.config?.homePath, defaultName: ".codex", home: home) else { continue }
                accounts.append(LocalCodingAccount(id: directory.path, kind: .codex, label: label(instance.displayName, fallback: "Codex"), homePath: directory.path))
            case "grok":
                let binary = instance.config?.binaryPath ?? ""
                let name = instance.displayName ?? ""
                if binary.localizedCaseInsensitiveContains("hermes") || name.localizedCaseInsensitiveContains("hermes") {
                    accounts.append(LocalCodingAccount(id: "hermes:\(key)", kind: .hermes, label: label(instance.displayName, fallback: "Hermes"), homePath: nil))
                } else {
                    accounts.append(LocalCodingAccount(id: "grok:\(key)", kind: .grok, label: label(instance.displayName, fallback: "Grok"), homePath: nil))
                }
            default:
                continue
            }
        }
        return accounts
    }

    private static func fallback(home: URL) -> [LocalCodingAccount] {
        let fm = FileManager.default
        var accounts: [LocalCodingAccount] = []
        let claude = home.appendingPathComponent(".claude", isDirectory: true)
        if fm.fileExists(atPath: claude.path) {
            accounts.append(LocalCodingAccount(id: claude.path, kind: .claude, label: "Claude Code", homePath: claude.path))
        }
        if let names = try? fm.contentsOfDirectory(atPath: home.path) {
            for name in names.sorted() where name.hasPrefix(".claude_") {
                let directory = home.appendingPathComponent(name, isDirectory: true)
                let marker = directory.appendingPathComponent(".claude.json").path
                let settings = directory.appendingPathComponent("settings.json").path
                guard fm.fileExists(atPath: marker) || fm.fileExists(atPath: settings) else { continue }
                accounts.append(LocalCodingAccount(id: directory.path, kind: .claude, label: name, homePath: directory.path))
            }
        }
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        if fm.fileExists(atPath: codex.path) {
            accounts.append(LocalCodingAccount(id: codex.path, kind: .codex, label: "Codex", homePath: codex.path))
        }
        let grok = home.appendingPathComponent(".grok", isDirectory: true)
        if fm.fileExists(atPath: grok.path) {
            accounts.append(LocalCodingAccount(id: "grok:local", kind: .grok, label: "Grok", homePath: nil))
        }
        return accounts
    }

    private static func label(_ displayName: String?, fallback: String) -> String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Empty `homePath` means the tool's default directory. Anything outside `home` is ignored.
    private static func resolved(_ raw: String?, defaultName: String, home: URL) -> URL? {
        let candidate: URL
        if let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidate = URL(fileURLWithPath: raw).standardizedFileURL
        } else {
            candidate = home.appendingPathComponent(defaultName, isDirectory: true).standardizedFileURL
        }
        let root = home.standardizedFileURL.path
        guard candidate.path == root || candidate.path.hasPrefix(root + "/") else { return nil }
        return candidate
    }
}

public struct GrokSpend: Equatable, Sendable {
    public let todayUSD: Decimal
    public let weekUSD: Decimal
    public let turnCount: Int
    public let observedAt: Date
    public static let ticksPerUSD = Decimal(10_000_000_000)

    public init(todayUSD: Decimal, weekUSD: Decimal, turnCount: Int, observedAt: Date) {
        self.todayUSD = todayUSD
        self.weekUSD = weekUSD
        self.turnCount = turnCount
        self.observedAt = observedAt
    }

    /// Sum turn costs. A session total is not used, because it would bill old work to the latest update.
    public static func summarize(_ files: [Data], now: Date, calendar: Calendar = .current) -> GrokSpend {
        let weekStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let todayStart = calendar.startOfDay(for: now)
        var today = Decimal(0)
        var week = Decimal(0)
        var turns = 0
        let decoder = JSONDecoder()
        for data in files {
            guard let envelope = try? decoder.decode(GrokUsageFile.self, from: data) else { continue }
            for turn in envelope.turns ?? [] {
                guard let ticks = turn.costUsdTicks, ticks >= 0,
                      let ended = turn.endedAt.flatMap(Self.parseDate),
                      ended <= now, ended >= weekStart else { continue }
                let dollars = Decimal(ticks) / ticksPerUSD
                week += dollars
                turns += 1
                if ended >= todayStart { today += dollars }
            }
        }
        return GrokSpend(todayUSD: today, weekUSD: week, turnCount: turns, observedAt: now)
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

private struct T3File: Decodable {
    let providerInstances: [String: T3Instance]?
}

private struct T3Instance: Decodable {
    let driver: String?
    let displayName: String?
    let enabled: Bool?
    let config: T3Config?
}

private struct T3Config: Decodable {
    let homePath: String?
    let binaryPath: String?
}

private struct GrokUsageFile: Decodable {
    let turns: [Turn]?
    struct Turn: Decodable {
        let endedAt: String?
        let costUsdTicks: Int64?
    }
}
