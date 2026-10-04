import XCTest
@testable import HeadroomCore

final class MoneySemanticsTests: XCTestCase {

    func testExactDecimalsAndSeparateCurrencies() throws {
        let jsonString = """
        {
            "is_available": true,
            "balance_infos": [
                {
                    "currency": "USD",
                    "total_balance": "10.5000",
                    "granted_balance": "2.5000",
                    "topped_up_balance": "8.0000"
                },
                {
                    "currency": "CNY",
                    "total_balance": "50.1234",
                    "granted_balance": "0.0000",
                    "topped_up_balance": "50.1234"
                }
            ]
        }
        """
        let data = Data(jsonString.utf8)
        let client = DeepSeekClient()
        let observation = try client.parseResponseData(
            data,
            connectionId: ConnectionID(),
            generationId: ConnectionGenerationID()
        )

        XCTAssertTrue(observation.isAvailable)
        XCTAssertEqual(observation.balances.count, 2)

        let usd = observation.balance(for: "USD")!
        XCTAssertEqual(usd.currency, "USD")
        XCTAssertEqual(usd.totalBalance, Decimal(string: "10.5000"))
        XCTAssertEqual(usd.grantedBalance, Decimal(string: "2.5000"))
        XCTAssertEqual(usd.toppedUpBalance, Decimal(string: "8.0000"))
        XCTAssertEqual(usd.rawTotal, "10.5000")

        let cny = observation.balance(for: "CNY")!
        XCTAssertEqual(cny.currency, "CNY")
        XCTAssertEqual(cny.totalBalance, Decimal(string: "50.1234"))
        XCTAssertEqual(cny.grantedBalance, Decimal(string: "0.0000"))
        XCTAssertEqual(cny.toppedUpBalance, Decimal(string: "50.1234"))

        // Verification: No mixed-currency total exists
        // USD and CNY remain strictly in separate rows
        XCTAssertNotEqual(usd.currency, cny.currency)
    }

    func testValidZeroAndNegativeAmountPreservation() throws {
        let jsonString = """
        {
            "is_available": false,
            "balance_infos": [
                {
                    "currency": "USD",
                    "total_balance": "-2.5000",
                    "granted_balance": "0.0000",
                    "topped_up_balance": "-2.5000"
                }
            ]
        }
        """
        let data = Data(jsonString.utf8)
        let client = DeepSeekClient()
        let observation = try client.parseResponseData(
            data,
            connectionId: ConnectionID(),
            generationId: ConnectionGenerationID()
        )

        // is_available flag is preserved independently of sign/amount
        XCTAssertFalse(observation.isAvailable)
        let usd = observation.balance(for: "USD")!
        XCTAssertEqual(usd.totalBalance, Decimal(string: "-2.5000"))
        XCTAssertEqual(usd.grantedBalance, Decimal(string: "0.0000"))
        XCTAssertEqual(usd.toppedUpBalance, Decimal(string: "-2.5000"))
    }

    func testSufficiencyFlagIndependentOfAmount() throws {
        // Test case where balance is zero, but is_available is true (e.g. free tier or active grant)
        let jsonString = """
        {
            "is_available": true,
            "balance_infos": [
                {
                    "currency": "USD",
                    "total_balance": "0.0000",
                    "granted_balance": "0.0000",
                    "topped_up_balance": "0.0000"
                }
            ]
        }
        """
        let data = Data(jsonString.utf8)
        let client = DeepSeekClient()
        let observation = try client.parseResponseData(
            data,
            connectionId: ConnectionID(),
            generationId: ConnectionGenerationID()
        )

        XCTAssertTrue(observation.isAvailable, "is_available flag must be preserved independently of zero balance")
        let usd = observation.balance(for: "USD")!
        XCTAssertEqual(usd.totalBalance, Decimal.zero)
    }

    func testMissingRequiredFieldsThrowsError() {
        // Missing is_available
        let missingIsAvailable = Data("""
        {
            "balance_infos": []
        }
        """.utf8)
        let client = DeepSeekClient()
        XCTAssertThrowsError(try client.parseResponseData(missingIsAvailable, connectionId: ConnectionID(), generationId: ConnectionGenerationID())) { error in
            guard case DeepSeekError.missingRequiredField(let field) = error else {
                XCTFail("Expected missingRequiredField but got \(error)")
                return
            }
            XCTAssertEqual(field, "is_available")
        }

        // Missing balance_infos
        let missingBalanceInfos = Data("""
        {
            "is_available": true
        }
        """.utf8)
        XCTAssertThrowsError(try client.parseResponseData(missingBalanceInfos, connectionId: ConnectionID(), generationId: ConnectionGenerationID())) { error in
            guard case DeepSeekError.missingRequiredField(let field) = error else {
                XCTFail("Expected missingRequiredField but got \(error)")
                return
            }
            XCTAssertEqual(field, "balance_infos")
        }
    }

    func testMalformedDecimalStringThrowsError() {
        let malformedDecimal = Data("""
        {
            "is_available": true,
            "balance_infos": [
                {
                    "currency": "USD",
                    "total_balance": "12.34.56",
                    "granted_balance": "0.0000",
                    "topped_up_balance": "12.34"
                }
            ]
        }
        """.utf8)
        let client = DeepSeekClient()
        XCTAssertThrowsError(try client.parseResponseData(malformedDecimal, connectionId: ConnectionID(), generationId: ConnectionGenerationID())) { error in
            guard case DeepSeekError.malformedResponse = error else {
                XCTFail("Expected malformedResponse but got \(error)")
                return
            }
        }
    }

    func testEmptyBalanceInfosPolicy() throws {
        // Conservative empty array policy: valid response with 0 rows, preserves is_available
        let emptyArray = Data("""
        {
            "is_available": false,
            "balance_infos": []
        }
        """.utf8)
        let client = DeepSeekClient()
        let observation = try client.parseResponseData(emptyArray, connectionId: ConnectionID(), generationId: ConnectionGenerationID())
        XCTAssertFalse(observation.isAvailable)
        XCTAssertEqual(observation.balances.count, 0)
    }

    func testOversizedResponseIsRejected() async {
        // Bounded response size check (> 64KB)
        var giantArray: [String] = []
        for i in 0..<1500 {
            giantArray.append("""
            {
                "currency": "USD",
                "total_balance": "\(i).0000",
                "granted_balance": "0.0000",
                "topped_up_balance": "\(i).0000"
            }
            """)
        }
        let giantJSON = """
        {
            "is_available": true,
            "balance_infos": [\(giantArray.joined(separator: ","))]
        }
        """
        let data = Data(giantJSON.utf8)
        XCTAssertGreaterThan(data.count, DeepSeekClient.maxResponseSizeBytes)

        let mockTransport = MockNetworkTransport { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.deepseek.com/user/balance")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        }

        let client = DeepSeekClient(transport: mockTransport)
        do {
            _ = try await client.fetchBalance(apiKey: "sk-test", connectionId: ConnectionID(), generationId: ConnectionGenerationID())
            XCTFail("Expected responseTooLarge error")
        } catch DeepSeekError.responseTooLarge {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOverprecisionFractionalDigitsRejectedWithoutDoubleLoss() {
        // Overprecision string exceeding Decimal's exact representable precision (38 significant digits)
        let overprecisionJSON = Data("""
        {
            "is_available": true,
            "balance_infos": [
                {
                    "currency": "USD",
                    "total_balance": "0.123456789012345678901234567890123456789012345678901",
                    "granted_balance": "0.0000",
                    "topped_up_balance": "0.123456789012345678901234567890123456789012345678901"
                }
            ]
        }
        """.utf8)
        let client = DeepSeekClient()
        XCTAssertThrowsError(try client.parseResponseData(overprecisionJSON, connectionId: ConnectionID(), generationId: ConnectionGenerationID())) { error in
            guard case DeepSeekError.malformedResponse = error else {
                XCTFail("Expected malformedResponse for overprecision Decimal string, got: \(error)")
                return
            }
        }
    }

    func testOverprecisionLargeIntegerWithFractionRejected() {
        // Exceeds 38 significant digits
        let largeOverprecision = Data("""
        {
            "is_available": true,
            "balance_infos": [
                {
                    "currency": "USD",
                    "total_balance": "1234567890123456789012345678901234567890.1",
                    "granted_balance": "0.0000",
                    "topped_up_balance": "1234567890123456789012345678901234567890.1"
                }
            ]
        }
        """.utf8)
        let client = DeepSeekClient()
        XCTAssertThrowsError(try client.parseResponseData(largeOverprecision, connectionId: ConnectionID(), generationId: ConnectionGenerationID())) { error in
            guard case DeepSeekError.malformedResponse = error else {
                XCTFail("Expected malformedResponse for large overprecision Decimal string, got: \(error)")
                return
            }
        }
    }

    func testParseErrorNeverEchoesRawCredentialOrMalformedValues() {
        let secretOrMalformed = "sk-sensitive-raw-token-12345"
        do {
            _ = try CurrencyBalance.parseStrict(
                currency: "USD",
                totalString: secretOrMalformed,
                grantedString: "0.0",
                toppedUpString: "0.0"
            )
            XCTFail("Expected parse failure")
        } catch let CurrencyBalance.ParseError.invalidDecimalString(field) {
            XCTAssertEqual(field, "total_balance")
            let description = CurrencyBalance.ParseError.invalidDecimalString(field: field).errorDescription ?? ""
            XCTAssertFalse(description.contains(secretOrMalformed), "Diagnostics must never echo raw input string")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
