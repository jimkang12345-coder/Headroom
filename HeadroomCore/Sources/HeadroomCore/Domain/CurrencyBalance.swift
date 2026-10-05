import Foundation

public struct CurrencyBalance: Hashable, Codable, Sendable, Identifiable {
    public var id: String { currency }

    public let currency: String
    public let totalBalance: Decimal
    public let grantedBalance: Decimal
    public let toppedUpBalance: Decimal
    public let rawTotal: String
    public let rawGranted: String
    public let rawToppedUp: String

    public enum ParseError: Error, LocalizedError, Equatable {
        case emptyCurrency
        case invalidDecimalString(field: String)
        case precisionLossOrUnrepresentable(field: String)
        case nonFiniteDecimal(field: String)

        public var errorDescription: String? {
            switch self {
            case .emptyCurrency:
                return "Currency code cannot be empty."
            case .invalidDecimalString(let field):
                return "Invalid decimal string for '\(field)'."
            case .precisionLossOrUnrepresentable(let field):
                return "Decimal precision loss or unrepresentable magnitude for '\(field)'."
            case .nonFiniteDecimal(let field):
                return "Decimal for '\(field)' is not finite."
            }
        }
    }

    public init(
        currency: String,
        totalBalance: Decimal,
        grantedBalance: Decimal,
        toppedUpBalance: Decimal,
        rawTotal: String? = nil,
        rawGranted: String? = nil,
        rawToppedUp: String? = nil
    ) {
        self.currency = currency
        self.totalBalance = totalBalance
        self.grantedBalance = grantedBalance
        self.toppedUpBalance = toppedUpBalance
        self.rawTotal = rawTotal ?? NSDecimalNumber(decimal: totalBalance).stringValue
        self.rawGranted = rawGranted ?? NSDecimalNumber(decimal: grantedBalance).stringValue
        self.rawToppedUp = rawToppedUp ?? NSDecimalNumber(decimal: toppedUpBalance).stringValue
    }

    /// Strict parser from raw strings as returned by DeepSeek or other wallet APIs
    public static func parseStrict(
        currency: String,
        totalString: String,
        grantedString: String,
        toppedUpString: String
    ) throws -> CurrencyBalance {
        let cleanCurrency = currency.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCurrency.isEmpty else {
            throw ParseError.emptyCurrency
        }

        let total = try parseDecimalStrict(totalString, fieldName: "total_balance")
        let granted = try parseDecimalStrict(grantedString, fieldName: "granted_balance")
        let toppedUp = try parseDecimalStrict(toppedUpString, fieldName: "topped_up_balance")

        return CurrencyBalance(
            currency: cleanCurrency,
            totalBalance: total,
            grantedBalance: granted,
            toppedUpBalance: toppedUp,
            rawTotal: totalString,
            rawGranted: grantedString,
            rawToppedUp: toppedUpString
        )
    }

    // Includes signs and surrounding whitespace. This also accommodates the plain-decimal
    // expansion of APICostMoney's 160-byte inputs with exponents from -128 through 128.
    static let maxDecimalStringBytes = 320

    public static func parseDecimalStrict(_ raw: String, fieldName: String) throws -> Decimal {
        // Normalize first so the shared input bound applies before trimming or scanning.
        guard let normalizedInput = normalizeDecimalString(raw) else {
            throw ParseError.invalidDecimalString(field: fieldName)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanner = Scanner(string: trimmed)
        scanner.locale = Locale(identifier: "en_US_POSIX")
        guard let decimal = scanner.scanDecimal(), scanner.isAtEnd else {
            throw ParseError.invalidDecimalString(field: fieldName)
        }

        guard !decimal.isNaN else {
            throw ParseError.nonFiniteDecimal(field: fieldName)
        }

        // Verify exact decimal representability without converting through Double.
        let parsedString = NSDecimalNumber(decimal: decimal).stringValue
        guard let normalizedParsed = normalizeDecimalString(parsedString),
              normalizedInput == normalizedParsed else {
            throw ParseError.precisionLossOrUnrepresentable(field: fieldName)
        }

        return decimal
    }

    /// Lossless normalization of a decimal string for exact comparison:
    /// strips harmless formatting differences (leading zeros in integer part, trailing zeros in fraction part)
    /// without rounding or losing significant digits. Inputs exceeding 320 UTF-8 bytes are rejected.
    public static func normalizeDecimalString(_ raw: String) -> String? {
        // Inspect only a bounded prefix, including whitespace, before allocating or trimming.
        guard raw.utf8.prefix(maxDecimalStringBytes + 1).count <= maxDecimalStringBytes else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let bytes = Array(trimmed.utf8)
        let isNegative = bytes[0] == 45
        var integerStart = 0
        if isNegative || bytes[0] == 43 {
            integerStart += 1
        }
        let integerEnd = bytes[integerStart...].firstIndex(of: 46) ?? bytes.endIndex
        let fractionStart = integerEnd < bytes.endIndex ? integerEnd + 1 : integerEnd
        var fractionEnd = bytes.endIndex

        // An additional decimal point or any non-ASCII digit is invalid.
        guard integerStart < integerEnd || fractionStart < fractionEnd,
              bytes[integerStart..<integerEnd].allSatisfy({ (48...57).contains($0) }),
              bytes[fractionStart..<fractionEnd].allSatisfy({ (48...57).contains($0) }) else {
            return nil
        }

        // Move slice boundaries in linear time; repeated String.count/removal can be quadratic.
        while integerStart < integerEnd && bytes[integerStart] == 48 {
            integerStart += 1
        }
        while fractionEnd > fractionStart && bytes[fractionEnd - 1] == 48 {
            fractionEnd -= 1
        }

        if integerStart == integerEnd && fractionStart == fractionEnd {
            return "0"
        }

        let sign = isNegative ? "-" : ""
        let intPart = integerStart == integerEnd ? "0" : String(decoding: bytes[integerStart..<integerEnd], as: UTF8.self)
        if fractionStart == fractionEnd {
            return "\(sign)\(intPart)"
        } else {
            let fracPart = String(decoding: bytes[fractionStart..<fractionEnd], as: UTF8.self)
            return "\(sign)\(intPart).\(fracPart)"
        }
    }

    /// Formatted display for currency with symbol
    public var formattedTotal: String {
        formatAmount(totalBalance)
    }

    public var formattedGranted: String {
        formatAmount(grantedBalance)
    }

    public var formattedToppedUp: String {
        formatAmount(toppedUpBalance)
    }

    public var currencySymbol: String {
        switch currency.uppercased() {
        case "USD":
            return "$"
        case "CNY":
            return "¥"
        case "EUR":
            return "€"
        case "GBP":
            return "£"
        default:
            return currency.uppercased() + " "
        }
    }

    private func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.currencySymbol = currencySymbol
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(currencySymbol)\(amount)"
    }
}
