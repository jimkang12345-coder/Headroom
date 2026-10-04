import XCTest
@testable import HeadroomCore

final class APICostClientTests: XCTestCase, @unchecked Sendable {
    private let now = ISO8601DateFormatter().date(from: "2026-10-04T12:34:56Z")!
    private func stamp(_ date: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: date)!.timeIntervalSince1970)
    }

    private func openAIPage(
        day: Int = 1, amount: String = "12.345678901234567890123456789",
        currency: String = "usd", hasMore: Bool = false, next: String = "null"
    ) -> String {
        let start = stamp("2026-10-0\(day)T00:00:00Z")
        let end = start + 86_400
        return """
        {"object":"page","data":[{"object":"bucket","start_time":\(start),"end_time":\(end),
        "results":[{"object":"organization.costs.result","amount":{"value":\(amount),"currency":"\(currency)"}}]}],
        "has_more":\(hasMore),"next_page":\(next)}
        """
    }

    private func anthropicPage(amount: String = "1234.56789") -> String {
        """
        {"data":[{"starting_at":"2026-10-01T00:00:00Z","ending_at":"2026-10-02T00:00:00Z",
        "results":[{"amount":"\(amount)","currency":"USD"}]}],"has_more":false,"next_page":null}
        """
    }

    private func transport(_ body: String, finalURL: URL? = nil, status: Int = 200, headers: [String: String]? = nil) -> MockNetworkTransport {
        MockNetworkTransport { request in
            (Data(body.utf8), HTTPURLResponse(url: finalURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
    }

    private func openAI(_ transport: NetworkTransport) async throws -> APICostObservation {
        let now = now
        return try await OpenAICostClient(transport: transport, dateProvider: { now }).fetchCurrentMonthCost(
            adminAPIKey: "sk-admin-synthetic", connectionId: ConnectionID(), generationId: ConnectionGenerationID()
        )
    }

    func testOpenAIExactAmountAuthFixedOriginAndUTCMonthPagination() async throws {
        let page1 = openAIPage(hasMore: true, next: #""cursor&https://example.invalid""#)
        let page2 = openAIPage(day: 2, amount: "0.1")
        let requests = RequestRecorder()
        let mock = MockNetworkTransport { request in
            await requests.append(request)
            let count = await requests.count
            return (Data((count == 1 ? page1 : page2).utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let reading = try await openAI(mock)
        XCTAssertEqual(reading.amount, Decimal(string: "12.445678901234567890123456789"))
        XCTAssertEqual(reading.currency, "USD")
        XCTAssertEqual(reading.providerId, .openai)
        XCTAssertEqual(reading.periodStart.timeIntervalSince1970, TimeInterval(stamp("2026-10-01T00:00:00Z")))
        XCTAssertEqual(reading.periodEnd, now)
        XCTAssertEqual(reading.reportedThrough.timeIntervalSince1970, TimeInterval(stamp("2026-10-03T00:00:00Z")))
        let captured = await requests.all
        XCTAssertEqual(captured.count, 2)
        for request in captured {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "api.openai.com")
            XCTAssertEqual(request.url?.path, "/v1/organization/costs")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-admin-synthetic")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
        }
        let query = URLComponents(url: captured[1].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "page" }?.value, "cursor&https://example.invalid")
        XCTAssertEqual(query.first { $0.name == "start_time" }?.value, String(stamp("2026-10-01T00:00:00Z")))
    }

    func testAnthropicCentsConversionAndSeparateAuth() async throws {
        let body = anthropicPage()
        let now = now
        let mock = MockNetworkTransport { request in
            XCTAssertEqual(request.url?.host, "api.anthropic.com")
            XCTAssertEqual(request.url?.path, "/v1/organizations/cost_report")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-admin01-synthetic")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "starting_at" }?.value, "2026-10-01T00:00:00Z")
            XCTAssertEqual(query.first { $0.name == "ending_at" }?.value, "2026-10-04T12:34:56Z")
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let reading = try await AnthropicCostClient(transport: mock, dateProvider: { now }).fetchCurrentMonthCost(
            adminAPIKey: "sk-ant-admin01-synthetic", connectionId: ConnectionID(), generationId: ConnectionGenerationID()
        )
        XCTAssertEqual(reading.amount, Decimal(string: "12.3456789"))
        XCTAssertEqual(reading.providerId, .anthropic)
        XCTAssertEqual(reading.reportedThrough, ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z"))
    }

    func testCredentialsAreRejectedBeforeAnyRequest() async {
        let requests = RequestRecorder()
        let body = openAIPage()
        let mock = MockNetworkTransport { request in
            await requests.append(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let now = now
        for key in ["", "sk-model-synthetic", "sk-admin-", "sk-admin-secret\nInjected: value", "sk-admin-☃"] {
            do {
                _ = try await OpenAICostClient(transport: mock, dateProvider: { now }).fetchCurrentMonthCost(
                    adminAPIKey: key, connectionId: ConnectionID(), generationId: ConnectionGenerationID()
                )
                XCTFail("Expected rejected reporting credential")
            } catch { XCTAssertEqual(error as? APICostError, .authFailure(statusCode: 401)) }
        }
        let count = await requests.count
        XCTAssertEqual(count, 0)
    }

    func testRedirectsAndUnexpectedResponseEndpointsAreRejected() async {
        for url in ["https://api.openai.com.attacker.invalid/v1/organization/costs", "http://api.openai.com/v1/organization/costs", "https://api.openai.com:8443/v1/organization/costs", "https://user:pass@api.openai.com/v1/organization/costs", "https://api.openai.com/v1/models"] {
            do {
                _ = try await openAI(transport(openAIPage(), finalURL: URL(string: url)!))
                XCTFail("Expected endpoint rejection")
            } catch { XCTAssertEqual(error as? APICostError, .invalidHost) }
        }
        do {
            _ = try await openAI(transport("private response ignored", status: 302))
            XCTFail("Expected redirect rejection")
        } catch { XCTAssertEqual(error as? APICostError, .redirectRejected) }
    }

    func testMalformedMoneyMissingAmountsCurrenciesAndDuplicateFieldsNeverBecomeZero() async {
        let missing = openAIPage().replacingOccurrences(of: #""amount":{"value":12.345678901234567890123456789,"currency":"usd"}"#, with: #""amount":null"#)
        let duplicate = openAIPage().replacingOccurrences(of: #""currency":"usd""#, with: #""currency":"usd","currency":"eur""#)
        for body in [openAIPage(amount: "true"), openAIPage(amount: #""1.2""#), openAIPage(amount: "0.1234567890123456789012345678901234567890123456789"), openAIPage(currency: "EUR"), missing, duplicate, "{\"data\":[]}"] {
            do { _ = try await openAI(transport(body)); XCTFail("Expected malformed report rejection") }
            catch { XCTAssertEqual(error as? APICostError, .malformedResponse) }
        }
        let now = now
        for amount in ["NaN", "1e3", " 12.3 ", "0.1234567890123456789012345678901234567890123456789"] {
            do {
                _ = try await AnthropicCostClient(transport: transport(anthropicPage(amount: amount)), dateProvider: { now }).fetchCurrentMonthCost(
                    adminAPIKey: "sk-ant-admin01-synthetic", connectionId: ConnectionID(), generationId: ConnectionGenerationID()
                )
                XCTFail("Expected malformed cents rejection")
            } catch { XCTAssertEqual(error as? APICostError, .malformedResponse) }
        }
    }

    func testCompleteEmptyReportAndExactExponentAmount() async throws {
        let empty = try await openAI(transport(#"{"object":"page","data":[],"has_more":false,"next_page":null}"#))
        XCTAssertEqual(empty.amount, 0)
        XCTAssertEqual(empty.reportedThrough, empty.periodStart)
        let exponent = try await openAI(transport(openAIPage(amount: "1.25e-8")))
        XCTAssertEqual(exponent.amount, Decimal(string: "0.0000000125"))
    }

    func testMissingRepeatedOrInconsistentCursorRejectsPartialReport() async {
        for body in [openAIPage(hasMore: true), openAIPage(hasMore: true, next: #""""#), openAIPage(hasMore: false, next: #""unexpected""#), openAIPage(hasMore: true, next: #""repeat""#)] {
            do { _ = try await openAI(transport(body)); XCTFail("Expected incomplete report rejection") }
            catch { XCTAssertEqual(error as? APICostError, .incompleteReport) }
        }
        let requests = RequestRecorder()
        let pages = [openAIPage(day: 1, hasMore: true, next: #""repeat""#), openAIPage(day: 2, hasMore: true, next: #""repeat""#)]
        let mock = MockNetworkTransport { request in
            await requests.append(request)
            let count = await requests.count
            return (Data(pages[count - 1].utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await openAI(mock); XCTFail("Expected repeated cursor rejection") }
        catch { XCTAssertEqual(error as? APICostError, .incompleteReport) }
        let count = await requests.count
        XCTAssertEqual(count, 2)
    }

    func testPaginationHasBoundedRequestsAndNoPartialTotal() async {
        let requests = RequestRecorder()
        let snapshots = (1...4).map { openAIPage(day: $0, amount: "10", hasMore: true, next: "\"cursor-\($0)\"") }
        let mock = MockNetworkTransport { request in
            await requests.append(request)
            let count = await requests.count
            return (Data(snapshots[count - 1].utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await openAI(mock); XCTFail("Expected page cap rejection") }
        catch { XCTAssertEqual(error as? APICostError, .incompleteReport) }
        let count = await requests.count
        XCTAssertEqual(count, 4)
    }

    func testOversizedResponseAndErrorsStaySanitized() async {
        do { _ = try await openAI(transport(String(repeating: "x", count: 262_145))); XCTFail("Expected byte cap") }
        catch { XCTAssertEqual(error as? APICostError, .responseTooLarge) }
        do { _ = try await openAI(transport("sk-admin-private-error-body", status: 403)); XCTFail("Expected auth failure") }
        catch {
            XCTAssertEqual(error as? APICostError, .authFailure(statusCode: 403))
            XCTAssertFalse(error.localizedDescription.contains("sk-admin-private-error-body"))
        }
    }

    func testRetryAfterIsFiniteBoundedAndInvalidValueUsesFallback() async {
        for (raw, delay) in [("Infinity", 60.0), ("NaN", 60.0), ("-20", 60.0), ("9999999999999999", 86_400.0), ("120", 120.0)] {
            do { _ = try await openAI(transport("ignored", status: 429, headers: ["Retry-After": raw])); XCTFail("Expected rate limit") }
            catch {
                XCTAssertEqual(error as? APICostError, .rateLimited(retryAfter: now.addingTimeInterval(delay)))
            }
        }
    }

    func testOutOfMonthAndOverlappingBucketsAreRejected() async {
        let outside = openAIPage().replacingOccurrences(of: String(stamp("2026-10-01T00:00:00Z")), with: String(stamp("2026-09-30T00:00:00Z")))
        do { _ = try await openAI(transport(outside)); XCTFail("Expected interval rejection") }
        catch { XCTAssertEqual(error as? APICostError, .malformedResponse) }
        do { _ = try await openAI(transport(openAIPage(hasMore: true, next: #""repeat""#))); XCTFail("Expected overlapping report rejection") }
        catch { XCTAssertEqual(error as? APICostError, .incompleteReport) }
    }

    func testLocalBudgetIsPositiveExactAndNotProviderBalance() throws {
        let budget = try LocalAPIMonthlyBudget.parse("50.125")
        XCTAssertEqual(budget.amount, Decimal(string: "50.125"))
        XCTAssertEqual(budget.currency, "USD")
        for invalid in ["0", "-1", "NaN", "1e3", "0.123456789012345678901234567890123456789012345"] {
            XCTAssertThrowsError(try LocalAPIMonthlyBudget.parse(invalid))
        }
        XCTAssertThrowsError(try LocalAPIMonthlyBudget(amount: 10, currency: "EUR"))
        XCTAssertEqual(ProviderID.codex.lifecycleStatus, .implemented)
        XCTAssertTrue(ProviderID.openai.supportsAPIConnection)
        XCTAssertFalse(ProviderID.codex.supportsAPIConnection)
    }
}

private actor RequestRecorder {
    private var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
    var count: Int { requests.count }
    var all: [URLRequest] { requests }
}
