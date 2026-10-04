import Foundation

enum UsageError: LocalizedError {
    case message(String)
}
let fm = FileManager.default
let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? fm.removeItem(at: home) }
try fm.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
let settings = home.appendingPathComponent(".claude/settings.json")
let original: [String: Any] = ["permissions": ["allow": ["Read"]], "statusLine": ["type": "command", "command": "printf original", "padding": 2]]
try JSONSerialization.data(withJSONObject: original).write(to: settings)
let integration = ClaudeUsageFeed(home: home)
try integration.install()
assert(integration.isInstalled)
// A second connect must not replace the original backup with the wrapper.
try integration.install()
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/bash")
process.arguments = [integration.directory.appendingPathComponent("claude-statusline.sh").path]
let input = Pipe(), output = Pipe()
process.standardInput = input
process.standardOutput = output
try process.run()
try input.fileHandleForWriting.write(contentsOf: Data(#"{"rate_limits":{"five_hour":{"used_percentage":37}},"session_id":"must-not-store","workspace":{"cwd":"private-path"}}"#.utf8))
try input.fileHandleForWriting.close()
process.waitUntilExit()
assert(process.terminationStatus == 0)
assert(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "original")
let feed = try String(contentsOf: integration.feed, encoding: .utf8)
assert(feed.contains("37") && !feed.contains("must-not-store") && !feed.contains("private-path"))
try integration.uninstall()
let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! NSDictionary
assert(restored.isEqual(to: original))
assert(!fm.fileExists(atPath: integration.feed.path))
// Preserve settings changed by the user after install.
try integration.install()
try JSONSerialization.data(withJSONObject: ["statusLine": ["command": "printf new"]]).write(to: settings)
try integration.uninstall()
let changed = try String(contentsOf: settings, encoding: .utf8)
assert(changed.contains("printf new"))
// Rewritten settings keep paths readable rather than JSON-escaping every slash.
try integration.install()
let rewritten = try String(contentsOf: settings, encoding: .utf8)
assert(!rewritten.contains(#"\/"#))
try integration.uninstall()
// Without jq, connecting fails before Claude settings are created or changed.
let bare = home.appendingPathComponent("no-jq")
let missing = ClaudeUsageFeed(home: bare, jqCandidates: [bare.appendingPathComponent("absent/jq").path])
do { try missing.install(); assertionFailure("Expected missing jq to be rejected") } catch {}
assert(!fm.fileExists(atPath: missing.settings.path))
// macOS 14 has no /usr/bin/jq; a later candidate (such as Homebrew's) is used instead.
let installedJQ = ClaudeUsageFeed.jqCandidates.first { fm.isExecutableFile(atPath: $0) }!
let fallbackHome = home.appendingPathComponent("fallback")
let fallback = ClaudeUsageFeed(home: fallbackHome, jqCandidates: [fallbackHome.appendingPathComponent("absent/jq").path, installedJQ])
try fallback.install()
let wrapper = Process()
wrapper.executableURL = URL(fileURLWithPath: "/bin/bash")
wrapper.arguments = [fallback.directory.appendingPathComponent("claude-statusline.sh").path]
let wrapperInput = Pipe(), wrapperOutput = Pipe()
wrapper.standardInput = wrapperInput
wrapper.standardOutput = wrapperOutput
try wrapper.run()
try wrapperInput.fileHandleForWriting.write(contentsOf: Data(#"{"rate_limits":{"seven_day":{"used_percentage":12}}}"#.utf8))
try wrapperInput.fileHandleForWriting.close()
wrapper.waitUntilExit()
assert(wrapper.terminationStatus == 0)
assert(String(data: wrapperOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == "Headroom · Claude\n")
let fallbackFeed = try String(contentsOf: fallback.feed, encoding: .utf8)
assert(fallbackFeed.contains("12"))
try fallback.uninstall()
let emptied = try JSONSerialization.jsonObject(with: Data(contentsOf: fallback.settings)) as? [String: Any]
assert(emptied?.isEmpty == true)
print("PASS: feed sanitization, existing display, idempotent install, exact restore, external settings preservation, readable settings, jq lookup")
