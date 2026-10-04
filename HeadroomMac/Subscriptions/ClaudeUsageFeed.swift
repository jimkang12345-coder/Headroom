import Foundation

/// Official statusLine integration; only quota fields are persisted.
struct ClaudeUsageFeed {
    /// macOS 15 and later include /usr/bin/jq; macOS 14 needs a Homebrew copy.
    static let jqCandidates = ["/usr/bin/jq", "/opt/homebrew/bin/jq", "/usr/local/bin/jq"]
    let directory: URL
    let settings: URL
    private let jqCandidates: [String]
    var feed: URL { directory.appendingPathComponent("claude-usage.json") }
    private var script: URL { directory.appendingPathComponent("claude-statusline.sh") }
    private var backup: URL { directory.appendingPathComponent("previous-statusline.json") }
    private var command: String { "/bin/bash " + quote(script.path) }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, jqCandidates: [String] = Self.jqCandidates) {
        directory = home.appendingPathComponent("Library/Application Support/Headroom/Subscriptions", isDirectory: true)
        settings = home.appendingPathComponent(".claude/settings.json")
        self.jqCandidates = jqCandidates
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settings.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any] else {
            throw UsageError.message("Claude settings could not be read. Existing settings were preserved.")
        }
        return object
    }
    private func write(_ value: [String: Any], to url: URL) throws {
        // Keep paths and URLs in the user's Claude settings readable ("/" rather than "\/").
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    var isInstalled: Bool {
        guard let config = try? readSettings(), let status = config["statusLine"] as? [String: Any] else { return false }
        return status["command"] as? String == command
    }

    func install() throws {
        let fm = FileManager.default
        guard let jq = jqCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw UsageError.message("The Claude Code feed requires jq. macOS 15 and later include it; on macOS 14, install it with Homebrew (brew install jq), then connect again.")
        }
        var config = try readSettings()
        if isInstalled { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = config["statusLine"] ?? NSNull()
        try write(["statusLine": previous], to: backup)
        let priorCommand = (previous as? [String: Any])?["command"] as? String
        let render = priorCommand.map { "printf '%s' \"$payload\" | /bin/sh -c " + quote($0) }
            ?? "printf '%s' \"$payload\" | " + quote(jq) + " -r '\"Headroom · \" + (.model.display_name // \"Claude\")'"
        // mktemp + rename prevents the reader seeing half a JSON object.
        let text = """
        #!/bin/bash
        umask 077
        payload=$(cat)
        temp=$(/usr/bin/mktemp \(quote(feed.path + ".XXXXXX"))) || exit 1
        trap '/bin/rm -f "$temp"' EXIT
        if printf '%s' "$payload" | \(quote(jq)) '{rate_limits: (.rate_limits // null)}' > "$temp"; then
          /bin/mv -f "$temp" \(quote(feed.path))
        fi
        \(render)
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        // A newly bound feed must never show a previous account's values.
        if fm.fileExists(atPath: feed.path) { try fm.removeItem(at: feed) }
        var status = previous as? [String: Any] ?? [:]
        status["type"] = "command"
        status["command"] = command
        config["statusLine"] = status
        try write(config, to: settings)
    }

    func uninstall() throws {
        var config = try readSettings()
        if isInstalled {
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any]
            guard let previous = saved?["statusLine"] else { throw UsageError.message("The original status line backup is unavailable; settings were preserved.") }
            if previous is NSNull { config.removeValue(forKey: "statusLine") }
            else { config["statusLine"] = previous }
            try write(config, to: settings)
        }
        if FileManager.default.fileExists(atPath: feed.path) { try FileManager.default.removeItem(at: feed) }
    }
}
