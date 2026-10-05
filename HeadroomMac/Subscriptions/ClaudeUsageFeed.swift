import Foundation

/// Official statusLine integration; only quota fields are persisted.
struct ClaudeUsageFeed {
    /// macOS 15 and later include /usr/bin/jq; macOS 14 needs a Homebrew copy.
    static let jqCandidates = ["/usr/bin/jq", "/opt/homebrew/bin/jq", "/usr/local/bin/jq"]
    let directory: URL
    let settings: URL
    private let jqCandidates: [String]
    private let generationPrefix = "claude-feed-"
    private let retiredPrefix = "retired-"
    private let scriptName = "claude-statusline.sh"
    private let backupName = "previous-statusline.json"
    var feed: URL {
        let installed = (try? readSettings()).flatMap { installation(in: $0) }
        return (installed ?? directory).appendingPathComponent("claude-usage.json")
    }

    private func command(in generation: URL) -> String {
        "/bin/bash " + quote(generation.appendingPathComponent(scriptName).path)
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, jqCandidates: [String] = Self.jqCandidates) {
        directory = home.appendingPathComponent("Library/Application Support/Headroom/Subscriptions", isDirectory: true)
        settings = home.appendingPathComponent(".claude/settings.json")
        self.jqCandidates = jqCandidates
    }

    private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    private func isGenerationName(_ name: String) -> Bool {
        guard name.hasPrefix(generationPrefix) else { return false }
        let identifier = String(name.dropFirst(generationPrefix.count))
        return UUID(uuidString: identifier)?.uuidString == identifier
    }
    /// Recognize our exact command even after its directory has been retired or deleted.
    private func installation(in config: [String: Any]) -> URL? {
        guard let status = config["statusLine"] as? [String: Any], let installed = status["command"] as? String else { return nil }
        if installed == command(in: directory) { return directory } // Legacy shared-path wrapper.
        let marker = "__HEADROOM_GENERATION__"
        let template = command(in: directory.appendingPathComponent(marker))
        let parts = template.components(separatedBy: marker)
        guard parts.count == 2, installed.hasPrefix(parts[0]), installed.hasSuffix(parts[1]),
              installed.count >= parts[0].count + parts[1].count else { return nil }
        let name = String(installed.dropFirst(parts[0].count).dropLast(parts[1].count))
        guard isGenerationName(name) else { return nil }
        return directory.appendingPathComponent(name, isDirectory: true)
    }
    private func generations() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter {
            isGenerationName($0.lastPathComponent) ||
                ($0.lastPathComponent.hasPrefix(retiredPrefix) && isGenerationName(String($0.lastPathComponent.dropFirst(retiredPrefix.count))))
        }
    }
    private func retired(_ generation: URL) -> URL {
        directory.appendingPathComponent(retiredPrefix + generation.lastPathComponent, isDirectory: true)
    }
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
        guard let config = try? readSettings() else { return false }
        return installation(in: config) != nil
    }
    /// Include orphaned/retired writers even when they never produced a feed or settings changed.
    var needsCleanup: Bool {
        if isInstalled { return true }
        do { if !(try generations()).isEmpty { return true } }
        catch { return true }
        return [scriptName, backupName, "claude-usage.json"].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    func install() throws {
        let fm = FileManager.default
        guard let jq = jqCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw UsageError.message("The Claude Code feed requires jq. macOS 15 and later include it; on macOS 14, install it with Homebrew (brew install jq), then connect again.")
        }
        var config = try readSettings()
        if let installed = installation(in: config), installed != directory {
            guard fm.fileExists(atPath: installed.appendingPathComponent(scriptName).path) else {
                throw UsageError.message("Finish removing the previous Claude Code feed before reconnecting.")
            }
            return
        }
        // Restore a legacy wrapper's saved command before migration; never back up or invoke
        // Headroom itself. Also clear generations abandoned by externally changed settings.
        if needsCleanup {
            try uninstall()
            config = try readSettings()
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Every install gets immutable paths. The writer must never recreate this directory.
        let generation = directory.appendingPathComponent(generationPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: generation, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let script = generation.appendingPathComponent(scriptName)
        let feed = generation.appendingPathComponent("claude-usage.json")
        let previous = config["statusLine"] ?? NSNull()
        try write(["statusLine": previous], to: generation.appendingPathComponent(backupName))
        let priorCommand = (previous as? [String: Any])?["command"] as? String
        let render = priorCommand.map { "printf '%s' \"$payload\" | /bin/sh -c " + quote($0) }
            ?? "printf '%s' \"$payload\" | " + quote(jq) + " -r '\"Headroom · \" + (.model.display_name // \"Claude\")'"
        // mktemp + rename prevents partial JSON. Retiring the parent directory invalidates
        // both paths atomically, including writers blocked on stdin or already holding a file.
        let text = """
        #!/bin/bash
        umask 077
        payload=$(cat)
        if temp=$(/usr/bin/mktemp \(quote(feed.path + ".XXXXXX")) 2>/dev/null); then
          trap '/bin/rm -f "$temp"' EXIT
          if printf '%s' "$payload" | \(quote(jq)) '{rate_limits: (.rate_limits // null)}' > "$temp"; then
            /bin/mv -f "$temp" \(quote(feed.path)) 2>/dev/null
          fi
        fi
        \(render)
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var status = previous as? [String: Any] ?? [:]
        status["type"] = "command"
        status["command"] = command(in: generation)
        config["statusLine"] = status
        try write(config, to: settings)
    }

    func uninstall() throws {
        let fm = FileManager.default
        // Revoke every current writer before settings I/O or deletion, either of which may
        // fail. Keep retired backups until settings restoration succeeds so cleanup is retryable.
        for generation in try generations() where isGenerationName(generation.lastPathComponent) {
            try fm.moveItem(at: generation, to: retired(generation))
        }
        var config = try readSettings()
        if let installed = installation(in: config) {
            let backupDirectory = installed == directory ? directory : retired(installed)
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: backupDirectory.appendingPathComponent(backupName))) as? [String: Any]
            guard let previous = saved?["statusLine"] else { throw UsageError.message("The original status line backup is unavailable; settings were preserved.") }
            if previous is NSNull { config.removeValue(forKey: "statusLine") }
            else { config["statusLine"] = previous }
            try write(config, to: settings)
        }
        for generation in try generations() { try fm.removeItem(at: generation) }
        for name in [scriptName, backupName, "claude-usage.json"] {
            let artifact = directory.appendingPathComponent(name)
            if fm.fileExists(atPath: artifact.path) { try fm.removeItem(at: artifact) }
        }
    }
}
