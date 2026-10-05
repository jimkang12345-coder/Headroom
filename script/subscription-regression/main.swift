import Foundation

enum UsageError: LocalizedError {
    case message(String)
}
let fm = FileManager.default
guard let root = ProcessInfo.processInfo.environment["HEADROOM_SUBSCRIPTION_TEST_ROOT"] else {
    fatalError("Run through run.sh so synthetic homes have an owned test directory")
}
let home = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("synthetic home's folder")
try fm.createDirectory(at: home, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: home) }
let installedJQ = ClaudeUsageFeed.jqCandidates.first { fm.isExecutableFile(atPath: $0) }!
let payload = #"{"rate_limits":{"five_hour":{"used_percentage":37}},"session_id":"must-not-store","workspace":{"cwd":"private-path"}}"#
let original: [String: Any] = ["permissions": ["allow": ["Read"]], "statusLine": ["type": "command", "command": "printf '%s' \"original's output\"", "padding": 2, "refreshInterval": 150]]

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError(message) }
}
func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
func writeJSON(_ object: [String: Any], to url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object).write(to: url)
}
func config(_ feed: ClaudeUsageFeed) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: feed.settings)) as! [String: Any]
}
func installedCommand(_ feed: ClaudeUsageFeed) throws -> String {
    try (config(feed)["statusLine"] as! [String: Any])["command"] as! String
}
func executable(_ text: String, at url: URL) throws {
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}
func waitFor(_ description: String, until predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(10)
    while !predicate(), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    check(predicate(), "Timed out waiting for \(description)")
}
func expectFailure(_ description: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected failure: \(description)") } catch {}
}
struct Writer {
    let process: Process
    let input: Pipe
    let output: Pipe
    let error: Pipe
}
var running: [Writer] = []
defer {
    for writer in running where writer.process.isRunning {
        try? writer.input.fileHandleForWriting.close()
        writer.process.terminate()
    }
}
func start(_ feed: ClaudeUsageFeed, environment: [String: String]? = nil) throws -> Writer {
    let writer = Writer(process: Process(), input: Pipe(), output: Pipe(), error: Pipe())
    writer.process.executableURL = URL(fileURLWithPath: "/bin/sh")
    writer.process.arguments = ["-c", try installedCommand(feed)]
    writer.process.standardInput = writer.input
    writer.process.standardOutput = writer.output
    writer.process.standardError = writer.error
    writer.process.environment = environment
    try writer.process.run()
    running.append(writer)
    return writer
}
func send(_ payload: String, to writer: Writer) throws {
    try writer.input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
    try writer.input.fileHandleForWriting.close()
}
func finish(_ writer: Writer, expecting display: String) {
    waitFor("status-line completion") { !writer.process.isRunning }
    writer.process.waitUntilExit()
    let errors = String(data: writer.error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    check(writer.process.terminationStatus == 0, "Status line failed: \(errors)")
    check(String(data: writer.output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == display, "Prior status-line output changed")
}
func restored(_ feed: ClaudeUsageFeed, to original: [String: Any]) throws {
    let actual = try config(feed) as NSDictionary
    check(actual.isEqual(to: original), "Settings did not restore exactly")
    check(!feed.needsCleanup, "Owned artifacts remained after successful cleanup")
}

let integration = ClaudeUsageFeed(home: home.appendingPathComponent("basic"))
try writeJSON(original, to: integration.settings)
try integration.install()
check(integration.isInstalled && integration.needsCleanup, "Installation not recognized")
let firstFeed = integration.feed
let firstCommand = try installedCommand(integration)
try integration.install()
check(try installedCommand(integration) == firstCommand, "Repeated install changed the generation")
let installedStatus = try config(integration)["statusLine"] as! [String: Any]
check(installedStatus["padding"] as? Int == 2 && installedStatus["refreshInterval"] as? Int == 150, "Status-line metadata changed")
let process = try start(integration)
try send(payload, to: process)
finish(process, expecting: "original's output")
let sanitized = try String(contentsOf: firstFeed, encoding: .utf8)
check(sanitized.contains("37") && !sanitized.contains("must-not-store") && !sanitized.contains("private-path"), "Feed contains more than quota fields")
let rewritten = try String(contentsOf: integration.settings, encoding: .utf8)
check(!rewritten.contains(#"\/"#), "Settings paths became JSON-escaped")
try integration.uninstall()
try restored(integration, to: original)
check(!fm.fileExists(atPath: firstFeed.path), "Published feed survived uninstall")
try integration.install()
check(integration.feed != firstFeed && !fm.fileExists(atPath: integration.feed.path), "Reconnection reused a generation or stale reading")
try writeJSON(["statusLine": ["command": "printf new"], "other": true], to: integration.settings)
try integration.uninstall()
try restored(integration, to: ["statusLine": ["command": "printf new"], "other": true])
print("PASS: sanitized quota, prior display/quoting, metadata, idempotent install, exact restore, external edits, fresh generations")

// A cat barrier proves the old shell has loaded the wrapper and is blocked consuming
// stdin. This uses only a test PATH shim, without adding a production hook.
for reconnect in [false, true] {
    let raceHome = home.appendingPathComponent(reconnect ? "stdin-reconnect" : "stdin-disconnect")
    let feed = ClaudeUsageFeed(home: raceHome)
    try writeJSON(original, to: feed.settings)
    try feed.install()
    let oldFeed = feed.feed
    let ready = raceHome.appendingPathComponent("cat-ready")
    let bin = raceHome.appendingPathComponent("test-bin")
    try executable("#!/bin/sh\nprintf ready > \(shellQuote(ready.path))\nexec /bin/cat\n", at: bin.appendingPathComponent("cat"))
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = bin.path + ":/usr/bin:/bin"
    let writer = try start(feed, environment: environment)
    waitFor("old writer to block on stdin") { fm.fileExists(atPath: ready.path) }
    check(!fm.fileExists(atPath: oldFeed.path), "Blocked writer unexpectedly published")
    try feed.uninstall()
    if reconnect {
        try feed.install()
        check(feed.feed != oldFeed, "Reconnection reused the old path")
        let current = try start(feed)
        try send(#"{"rate_limits":{"five_hour":{"used_percentage":12}}}"#, to: current)
        finish(current, expecting: "original's output")
    }
    let newContents = reconnect ? try Data(contentsOf: feed.feed) : nil
    try send(payload, to: writer)
    finish(writer, expecting: "original's output")
    check(!fm.fileExists(atPath: oldFeed.deletingLastPathComponent().path), "Blocked old writer recreated its generation")
    if let newContents { check(try Data(contentsOf: feed.feed) == newContents, "Old writer changed the reconnected feed") }
    try feed.uninstall()
    try restored(feed, to: original)
}
print("PASS: disconnect while stdin is blocked, disconnect/reconnect while old writer is blocked")

// Pause jq after writing the temporary file, immediately before publication. Its output
// descriptor remains open across retirement, covering the final-check TOCTOU boundary.
for reconnect in [false, true] {
    let raceHome = home.appendingPathComponent(reconnect ? "publish-reconnect" : "publish-disconnect")
    let ready = raceHome.appendingPathComponent("jq-ready")
    let release = raceHome.appendingPathComponent("jq-release")
    let jq = raceHome.appendingPathComponent("test-bin/jq")
    try executable("""
    #!/bin/sh
    \(shellQuote(installedJQ)) "$@" || exit $?
    printf ready > \(shellQuote(ready.path))
    while [ ! -e \(shellQuote(release.path)) ]; do /bin/sleep 0.01; done
    """, at: jq)
    let feed = ClaudeUsageFeed(home: raceHome, jqCandidates: [jq.path])
    try writeJSON(original, to: feed.settings)
    try feed.install()
    let oldFeed = feed.feed
    let writer = try start(feed)
    try send(payload, to: writer)
    waitFor("temporary quota file before publication") { fm.fileExists(atPath: ready.path) }
    let files = try fm.contentsOfDirectory(atPath: oldFeed.deletingLastPathComponent().path)
    check(files.contains { $0.hasPrefix("claude-usage.json.") }, "Prepublication barrier did not hold a tempfile")
    try feed.uninstall()
    if reconnect { try feed.install(); check(feed.feed != oldFeed, "Prepublication reconnect reused old path") }
    try Data().write(to: release)
    finish(writer, expecting: "original's output")
    check(!fm.fileExists(atPath: oldFeed.deletingLastPathComponent().path), "Prepublication writer recreated retired path")
    check(!fm.fileExists(atPath: feed.feed.path), "Prepublication writer published after disconnect")
    try feed.uninstall()
    try restored(feed, to: original)
}
print("PASS: disconnect and reconnect while a writer holds the prepublication temporary file")

// A restore error must leave the writer retired and its original backup recoverable.
let retry = ClaudeUsageFeed(home: home.appendingPathComponent("retry"))
try writeJSON(original, to: retry.settings)
try retry.install()
let retryGeneration = retry.feed.deletingLastPathComponent()
let retiredGeneration = retry.directory.appendingPathComponent("retired-" + retryGeneration.lastPathComponent)
let savedBackup = try Data(contentsOf: retryGeneration.appendingPathComponent("previous-statusline.json"))
try writeJSON(["invalid": true], to: retryGeneration.appendingPathComponent("previous-statusline.json"))
expectFailure("invalid restore backup") { try retry.uninstall() }
check(!fm.fileExists(atPath: retryGeneration.path) && retry.needsCleanup, "Restore failure did not retire writer or retain cleanup state")
expectFailure("install during incomplete cleanup") { try retry.install() }
try savedBackup.write(to: retiredGeneration.appendingPathComponent("previous-statusline.json"))
try retry.uninstall()
try restored(retry, to: original)

// Settings parse failures must not keep generation writers active, and cleanup must retry.
try retry.install()
let malformedGeneration = retry.feed.deletingLastPathComponent()
let validSettings = try Data(contentsOf: retry.settings)
try Data("not-json".utf8).write(to: retry.settings)
expectFailure("malformed settings") { try retry.uninstall() }
check(!fm.fileExists(atPath: malformedGeneration.path) && retry.needsCleanup, "Malformed settings left active writer")
try validSettings.write(to: retry.settings)
try retry.uninstall()
try restored(retry, to: original)

// Failed retirement is propagated and detectable even with externally edited settings.
try retry.install()
let collisionGeneration = retry.feed.deletingLastPathComponent()
let collisionRetired = retry.directory.appendingPathComponent("retired-" + collisionGeneration.lastPathComponent)
try fm.createDirectory(at: collisionRetired, withIntermediateDirectories: false)
try writeJSON(["statusLine": ["command": "printf external"]], to: retry.settings)
expectFailure("retirement destination collision") { try retry.uninstall() }
check(retry.needsCleanup && fm.fileExists(atPath: collisionGeneration.path), "Failed retirement lost cleanup state")
try fm.removeItem(at: collisionRetired)
try retry.uninstall()
try restored(retry, to: ["statusLine": ["command": "printf external"]])

// A directory that permits retirement but not child deletion leaves detectable retired
// artifacts after settings were restored; a later cleanup must remove those too.
try retry.install()
let undeletable = retry.feed.deletingLastPathComponent()
let retiredUndeletable = retry.directory.appendingPathComponent("retired-" + undeletable.lastPathComponent)
try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: undeletable.path)
expectFailure("retired directory deletion") { try retry.uninstall() }
check(!retry.isInstalled && retry.needsCleanup && !fm.fileExists(atPath: undeletable.path), "Deletion error lost retired cleanup state")
try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: retiredUndeletable.path)
try retry.uninstall()
try restored(retry, to: ["statusLine": ["command": "printf external"]])
print("PASS: restore, malformed-settings, retirement/deletion errors propagate; retired/orphan cleanup retries without a feed")

// Recover a legacy backup without recursively invoking Headroom. Already running legacy
// shells cannot acquire the generation guarantee until the external client restarts them.
let legacy = ClaudeUsageFeed(home: home.appendingPathComponent("legacy"))
try fm.createDirectory(at: legacy.directory, withIntermediateDirectories: true)
let legacyScript = legacy.directory.appendingPathComponent("claude-statusline.sh")
let legacyCommand = "/bin/bash " + shellQuote(legacyScript.path)
try executable("#!/bin/sh\nprintf must-not-invoke-legacy\n", at: legacyScript)
try writeJSON(["statusLine": original["statusLine"]!], to: legacy.directory.appendingPathComponent("previous-statusline.json"))
var legacySettings = original
legacySettings["statusLine"] = ["type": "command", "command": legacyCommand, "padding": 2]
try writeJSON(legacySettings, to: legacy.settings)
check(legacy.isInstalled, "Legacy command not recognized")
try legacy.install()
check(try installedCommand(legacy) != legacyCommand, "Legacy installation did not migrate")
let legacyWriter = try start(legacy)
try send(payload, to: legacyWriter)
finish(legacyWriter, expecting: "original's output")
try legacy.uninstall()
try restored(legacy, to: original)
// A lost legacy backup must preserve the owned command and fail instead of saving the
// Headroom wrapper as its own previous command.
try executable("#!/bin/sh\nprintf legacy\n", at: legacyScript)
try writeJSON(legacySettings, to: legacy.settings)
expectFailure("missing legacy backup") { try legacy.install() }
check(try installedCommand(legacy) == legacyCommand, "Missing legacy backup changed settings")
check(legacy.needsCleanup, "Broken legacy installation lost cleanup state")
try writeJSON(["statusLine": original["statusLine"]!], to: legacy.directory.appendingPathComponent("previous-statusline.json"))
try legacy.uninstall()
try restored(legacy, to: original)
print("PASS: legacy migration preserves original display/backup without recursive wrapper invocation")

let bare = home.appendingPathComponent("no-jq")
let missing = ClaudeUsageFeed(home: bare, jqCandidates: [bare.appendingPathComponent("absent/jq").path])
expectFailure("missing jq") { try missing.install() }
check(!fm.fileExists(atPath: missing.settings.path) && !missing.needsCleanup, "Missing jq changed settings or created artifacts")
let fallbackHome = home.appendingPathComponent("fallback")
let fallback = ClaudeUsageFeed(home: fallbackHome, jqCandidates: [fallbackHome.appendingPathComponent("absent/jq").path, installedJQ])
try fallback.install()
let fallbackWriter = try start(fallback)
try send(#"{"rate_limits":{"seven_day":{"used_percentage":12}}}"#, to: fallbackWriter)
finish(fallbackWriter, expecting: "Headroom · Claude\n")
let fallbackFeed = try String(contentsOf: fallback.feed, encoding: .utf8)
check(fallbackFeed.contains("12"), "Fallback jq did not publish")
try fallback.uninstall()
try restored(fallback, to: [:])
print("PASS: missing jq has no effects, later jq candidates work, default display and empty-settings restoration")
