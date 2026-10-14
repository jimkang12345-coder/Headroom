import Foundation
import HeadroomCore

/// Read Claude subscription windows from the same endpoint Claude Code uses.
enum ClaudeAccountUsageClient {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func read(configDirectory: URL) async throws -> SubscriptionUsage {
        let token = try keychainToken(configDirectory: configDirectory)
        let data = try await fetch(token: token)
        return try SubscriptionUsage.claudeOAuth(data)
    }

    private static func keychainToken(configDirectory: URL) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
        let service = ClaudeCredentialLocator.service(configDirectory: configDirectory, defaultDirectory: home)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw UsageError.message("Headroom could not read this Claude account’s saved sign-in.")
        }
        guard let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            throw UsageError.message("This Claude account has no saved sign-in Headroom can read.")
        }
        return token
    }

    private static func fetch(token: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral, delegate: RedirectRefuse(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.message("Claude account limits could not be read.")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw UsageError.message("This Claude sign-in needs a refresh. Open Claude Code for this account once, then the limit bars will load.")
            }
            throw UsageError.message("Claude account limits could not be read (HTTP \(http.statusCode)).")
        }
        guard data.count <= 1_000_000 else { throw UsageError.message("Claude’s usage response is too large.") }
        return data
    }
}

private final class RedirectRefuse: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
