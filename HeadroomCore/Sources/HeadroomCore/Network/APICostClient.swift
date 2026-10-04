import Foundation

/// Read-only organization billing reports. This client never makes model-generation calls.
public final class OpenAICostClient: @unchecked Sendable {
    private let client: OrganizationCostClient

    public init(
        transport: NetworkTransport = SecureURLSessionTransport(maxResponseBytes: 262_144),
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        client = OrganizationCostClient(provider: .openai, transport: transport, dateProvider: dateProvider)
    }

    public func fetchCurrentMonthCost(
        adminAPIKey: String,
        connectionId: ConnectionID,
        generationId: ConnectionGenerationID
    ) async throws -> APICostObservation {
        try await client.fetch(adminAPIKey: adminAPIKey, connectionId: connectionId, generationId: generationId)
    }
}

/// Claude Console organization costs; excludes Priority Tier and Claude subscription quotas.
/// The report's decimal-string amounts are cents and are converted exactly to USD dollars.
public final class AnthropicCostClient: @unchecked Sendable {
    private let client: OrganizationCostClient

    public init(
        transport: NetworkTransport = SecureURLSessionTransport(maxResponseBytes: 262_144),
        dateProvider: @escaping @Sendable () -> Date = { Date() }
    ) {
        client = OrganizationCostClient(provider: .anthropic, transport: transport, dateProvider: dateProvider)
    }

    public func fetchCurrentMonthCost(
        adminAPIKey: String,
        connectionId: ConnectionID,
        generationId: ConnectionGenerationID
    ) async throws -> APICostObservation {
        try await client.fetch(adminAPIKey: adminAPIKey, connectionId: connectionId, generationId: generationId)
    }
}

private final class OrganizationCostClient: @unchecked Sendable {
    let provider: ProviderID
    let transport: NetworkTransport
    let dateProvider: @Sendable () -> Date
    static let maxResponseBytes = 262_144
    static let maxPages = 4

    init(provider: ProviderID, transport: NetworkTransport, dateProvider: @escaping @Sendable () -> Date) {
        self.provider = provider
        self.transport = transport
        self.dateProvider = dateProvider
    }

    var host: String { provider == .openai ? "api.openai.com" : "api.anthropic.com" }
    var path: String { provider == .openai ? "/v1/organization/costs" : "/v1/organizations/cost_report" }

    func fetch(
        adminAPIKey: String,
        connectionId: ConnectionID,
        generationId: ConnectionGenerationID
    ) async throws -> APICostObservation {
        let key = adminAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = provider == .openai ? "sk-admin-" : "sk-ant-admin01-"
        guard key.hasPrefix(prefix), key.count > prefix.count, key.utf8.count <= 1_024,
              key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw APICostError.authFailure(statusCode: 401)
        }
        let timestamp = dateProvider().timeIntervalSince1970
        guard timestamp.isFinite, timestamp > 0, timestamp < 253_402_300_799 else {
            throw APICostError.malformedResponse
        }
        let now = Date(timeIntervalSince1970: floor(timestamp))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let start = utc.dateInterval(of: .month, for: now)?.start else {
            throw APICostError.malformedResponse
        }
        let latestPossibleBucketEnd = utc.startOfDay(for: now).addingTimeInterval(86_400)
        var total = Decimal.zero
        var cursor: String?
        var seenCursors = Set<String>()
        var intervals: [(Date, Date)] = []
        var reportedThrough = start
        var resultCount = 0

        for pageIndex in 0..<Self.maxPages {
            guard !Task.isCancelled else { throw APICostError.cancelled }
            let request = try request(key: key, start: start, end: now, cursor: cursor)
            let (data, response) = try await send(request)
            guard !Task.isCancelled else { throw APICostError.cancelled }
            guard data.count <= Self.maxResponseBytes else { throw APICostError.responseTooLarge }
            guard let url = response.url, let endpoint = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  endpoint.scheme == "https", endpoint.host == host,
                  endpoint.port == nil || endpoint.port == 443,
                  endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
                  endpoint.path == path else { throw APICostError.invalidHost }
            try checkStatus(response, now: now)

            let report = try APICostJSON.parse(data)
            if provider == .openai {
                guard try report.field("object").text == "page" else { throw APICostError.malformedResponse }
            }
            let buckets = try report.field("data").values
            guard intervals.count + buckets.count <= 64 else { throw APICostError.incompleteReport }
            for bucket in buckets {
                let bucketStart: Date
                let bucketEnd: Date
                if provider == .openai {
                    guard try bucket.field("object").text == "bucket" else { throw APICostError.malformedResponse }
                    bucketStart = Date(timeIntervalSince1970: TimeInterval(try bucket.field("start_time").integer))
                    bucketEnd = Date(timeIntervalSince1970: TimeInterval(try bucket.field("end_time").integer))
                } else {
                    bucketStart = try date(try bucket.field("starting_at").text)
                    bucketEnd = try date(try bucket.field("ending_at").text)
                }
                guard bucketStart >= start, bucketStart < now, bucketEnd > bucketStart,
                      bucketEnd <= latestPossibleBucketEnd,
                      bucketEnd.timeIntervalSince(bucketStart) <= 86_400,
                      bucketStart == utc.startOfDay(for: bucketStart),
                      provider != .anthropic || bucketEnd <= now else { throw APICostError.malformedResponse }
                guard !intervals.contains(where: { bucketStart < $0.1 && bucketEnd > $0.0 }) else {
                    throw APICostError.incompleteReport
                }
                intervals.append((bucketStart, bucketEnd))
                reportedThrough = max(reportedThrough, min(bucketEnd, now))
                for result in try bucket.field("results").values {
                    resultCount += 1
                    guard resultCount <= 4_096 else { throw APICostError.responseTooLarge }
                    let amount: Decimal
                    if provider == .openai {
                        guard try result.field("object").text == "organization.costs.result" else {
                            throw APICostError.malformedResponse
                        }
                        let money = try result.field("amount")
                        guard try money.field("currency").text.lowercased() == "usd",
                              case .number(let raw) = try money.field("value") else {
                            throw APICostError.malformedResponse
                        }
                        amount = try APICostMoney.decimal(raw, allowExponent: true)
                    } else {
                        guard try result.field("currency").text == "USD" else { throw APICostError.malformedResponse }
                        amount = try APICostMoney.dollars(fromCents: APICostMoney.decimal(
                            try result.field("amount").text, allowExponent: false
                        ))
                    }
                    try APICostMoney.add(amount, to: &total)
                }
            }

            guard case .bool(let hasMore) = try report.field("has_more") else {
                throw APICostError.malformedResponse
            }
            let next = try report.field("next_page")
            if !hasMore {
                guard case .null = next else { throw APICostError.incompleteReport }
                return APICostObservation(
                    connectionId: connectionId, generationId: generationId, providerId: provider,
                    amount: total, periodStart: start, periodEnd: now, capturedAt: now,
                    reportedThrough: reportedThrough
                )
            }
            guard pageIndex + 1 < Self.maxPages, !buckets.isEmpty,
                  case .string(let token) = next, !token.isEmpty, token.utf8.count <= 1_024,
                  token.utf8.allSatisfy({ (33...126).contains($0) }), seenCursors.insert(token).inserted else {
                throw APICostError.incompleteReport
            }
            cursor = token
        }
        throw APICostError.incompleteReport
    }

    func request(key: String, start: Date, end: Date, cursor: String?) throws -> URLRequest {
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        url.path = path
        if provider == .openai {
            url.queryItems = [
                URLQueryItem(name: "start_time", value: String(Int64(start.timeIntervalSince1970))),
                URLQueryItem(name: "end_time", value: String(Int64(end.timeIntervalSince1970)))
            ]
        } else {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            url.queryItems = [
                URLQueryItem(name: "starting_at", value: formatter.string(from: start)),
                URLQueryItem(name: "ending_at", value: formatter.string(from: end))
            ]
        }
        url.queryItems?.append(URLQueryItem(name: "bucket_width", value: "1d"))
        url.queryItems?.append(URLQueryItem(name: "limit", value: "31"))
        if let cursor { url.queryItems?.append(URLQueryItem(name: "page", value: cursor)) }
        guard let endpoint = url.url else { throw APICostError.invalidHost }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Headroom/1.0", forHTTPHeaderField: "User-Agent")
        if provider == .openai { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        else {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await transport.send(request: request) }
        catch let error as APICostError { throw error }
        catch is CancellationError { throw APICostError.cancelled }
        catch let error as DeepSeekError {
            switch error {
            case .offline: throw APICostError.offline
            case .timeout: throw APICostError.timeout
            case .cancelled: throw APICostError.cancelled
            case .responseTooLarge: throw APICostError.responseTooLarge
            case .redirectRejected: throw APICostError.redirectRejected
            default: throw APICostError.networkError
            }
        }
        catch { throw APICostError.networkError }
    }

    func checkStatus(_ response: HTTPURLResponse, now: Date) throws {
        switch response.statusCode {
        case 200: return
        case 300...399: throw APICostError.redirectRejected
        case 401, 403: throw APICostError.authFailure(statusCode: response.statusCode)
        case 429: throw APICostError.rateLimited(retryAfter: retryAfter(response, now: now))
        case 500...599: throw APICostError.serverError(statusCode: response.statusCode)
        default: throw APICostError.malformedResponse
        }
    }

    func retryAfter(_ response: HTTPURLResponse, now: Date) -> Date {
        let maxDelay: TimeInterval = 86_400
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"), raw.utf8.count <= 128 else {
            return now.addingTimeInterval(60)
        }
        if let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(min(seconds, maxDelay))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.isLenient = false
        if let deadline = formatter.date(from: raw), deadline >= now {
            return min(deadline, now.addingTimeInterval(maxDelay))
        }
        return now.addingTimeInterval(60)
    }

    func date(_ raw: String) throws -> Date {
        guard raw.utf8.count <= 40, raw.hasSuffix("Z") else { throw APICostError.malformedResponse }
        let formatter = ISO8601DateFormatter()
        if let result = formatter.date(from: raw) { return result }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let result = formatter.date(from: raw) else { throw APICostError.malformedResponse }
        return result
    }
}
