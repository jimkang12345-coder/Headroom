import Foundation

public final class DeepSeekClient: @unchecked Sendable {
    public static let defaultBaseURL = URL(string: "https://api.deepseek.com")!
    public static let balancePath = "/user/balance"
    public static let maxResponseSizeBytes = 65536 // 64 KB

    private let transport: NetworkTransport
    private let baseURL: URL
    private let dateProvider: @Sendable () -> Date

    public init(
        transport: NetworkTransport = SecureURLSessionTransport(),
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = Self.defaultBaseURL
        self.transport = transport
        self.dateProvider = dateProvider
    }

    /// Test-only initializer allowing base URL override. Production code must use the default initializer.
    init(
        baseURL: URL,
        transport: NetworkTransport,
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.dateProvider = dateProvider
    }

    public func fetchBalance(
        apiKey: String,
        connectionId: ConnectionID,
        generationId: ConnectionGenerationID
    ) async throws -> WalletObservation {
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanKey.isEmpty else {
            throw DeepSeekError.authFailure(statusCode: 401)
        }

        // Strict production endpoint validation (Repair E)
        guard isValidEndpoint(baseURL: baseURL) else {
            throw DeepSeekError.invalidHost
        }

        let endpointURL = baseURL.appendingPathComponent(Self.balancePath)
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Headroom/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await transport.send(request: request)

        // Bounded response size check in client as well
        if data.count > Self.maxResponseSizeBytes {
            throw DeepSeekError.responseTooLarge
        }

        let now = dateProvider()

        // Status code checking with sanitized local diagnostics
        switch response.statusCode {
        case 200...299:
            break // Success path
        case 401, 403:
            throw DeepSeekError.authFailure(statusCode: response.statusCode)
        case 429:
            let retryAfterDeadline = parseRetryAfter(from: response, now: now)
            throw DeepSeekError.rateLimited(retryAfter: retryAfterDeadline)
        case 500...599:
            throw DeepSeekError.serverError(statusCode: response.statusCode)
        default:
            throw DeepSeekError.invalidResponseFormat
        }

        // Strict JSON parsing
        return try parseResponseData(
            data,
            connectionId: connectionId,
            generationId: generationId,
            capturedAt: now
        )
    }

    public func parseResponseData(
        _ data: Data,
        connectionId: ConnectionID,
        generationId: ConnectionGenerationID,
        capturedAt: Date? = nil
    ) throws -> WalletObservation {
        let decoder = JSONDecoder()
        let rawResponse: RawDeepSeekResponse
        do {
            rawResponse = try decoder.decode(RawDeepSeekResponse.self, from: data)
        } catch {
            throw DeepSeekError.malformedResponse
        }

        guard let isAvailable = rawResponse.is_available else {
            throw DeepSeekError.missingRequiredField(field: "is_available")
        }

        guard let balanceInfos = rawResponse.balance_infos else {
            throw DeepSeekError.missingRequiredField(field: "balance_infos")
        }

        var parsedBalances: [CurrencyBalance] = []

        for info in balanceInfos {
            guard let currency = info.currency else {
                throw DeepSeekError.missingRequiredField(field: "currency")
            }
            guard let totalStr = info.total_balance else {
                throw DeepSeekError.missingRequiredField(field: "total_balance")
            }
            guard let grantedStr = info.granted_balance else {
                throw DeepSeekError.missingRequiredField(field: "granted_balance")
            }
            guard let toppedUpStr = info.topped_up_balance else {
                throw DeepSeekError.missingRequiredField(field: "topped_up_balance")
            }

            do {
                let parsed = try CurrencyBalance.parseStrict(
                    currency: currency,
                    totalString: totalStr,
                    grantedString: grantedStr,
                    toppedUpString: toppedUpStr
                )
                parsedBalances.append(parsed)
            } catch {
                throw DeepSeekError.malformedResponse
            }
        }

        return WalletObservation(
            connectionId: connectionId,
            generationId: generationId,
            isAvailable: isAvailable,
            balances: parsedBalances,
            capturedAt: capturedAt ?? dateProvider(),
            sourceTimestamp: nil
        )
    }

    private func isValidEndpoint(baseURL: URL) -> Bool {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        guard components.scheme == "https" else {
            return false
        }
        guard components.host == "api.deepseek.com" else {
            return false
        }
        if let port = components.port, port != 443 {
            return false
        }
        let path = components.path
        if !path.isEmpty && path != "/" {
            return false
        }
        guard components.user == nil, components.password == nil else {
            return false
        }
        guard components.query == nil, components.fragment == nil else {
            return false
        }
        return true
    }

    private func parseRetryAfter(from response: HTTPURLResponse, now: Date) -> Date {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return now.addingTimeInterval(60) // Bounded fallback if missing
        }

        if let seconds = Double(raw), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ]
        for fmt in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = fmt
            if let date = formatter.date(from: raw) {
                return date
            }
        }

        return now.addingTimeInterval(60) // Bounded fallback if unparseable
    }
}
