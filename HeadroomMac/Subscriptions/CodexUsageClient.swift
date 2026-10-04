import Foundation
import Darwin
import HeadroomCore

/// Read-only RPC. Authentication stays with the official Codex CLI.
enum CodexUsageClient {
    static var executable: String? {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/.codex/plugins/.plugin-appserver/codex-cli/bin/codex",
            NSHomeDirectory() + "/.codex/plugins/.plugin-appserver/codex",
            NSHomeDirectory() + "/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func read() throws -> SubscriptionUsage {
        guard let executable else { throw UsageError.message("Install Codex on this Mac, sign in, then connect again.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        // Apps opened from Finder get a minimal PATH; an npm-installed codex needs `node` beside it.
        var environment = ProcessInfo.processInfo.environment
        let toolDirectories = [(executable as NSString).deletingLastPathComponent, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (toolDirectories + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // A wedged child must not survive each refresh.
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "headroom", "version": "1.0"], "capabilities": NSNull()]])
        var buffer = Data()
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 200) > 0 else { continue }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            guard buffer.count <= 1_048_576 else { throw UsageError.message("Codex returned an oversized response.") }
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: end)
                buffer.removeSubrange(...end)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int else { continue }
                if object["error"] != nil { throw UsageError.message("Codex could not read subscription limits. Sign in to Codex with your ChatGPT account and try again.") }
                if id == 1 {
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": [:]])
                } else if id == 2, let result = object["result"] as? [String: Any] {
                    return try SubscriptionUsage.codex(JSONSerialization.data(withJSONObject: result))
                }
            }
        }
        throw UsageError.message("Codex did not return limits within 25 seconds. Check your sign-in and connection, then retry.")
    }
}

enum UsageError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
