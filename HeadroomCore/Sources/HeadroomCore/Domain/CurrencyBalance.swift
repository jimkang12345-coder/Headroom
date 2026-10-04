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

    public static func parseDecimalStrict(_ raw: String, fieldName: String) throws -> Decimal {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ParseError.invalidDecimalString(field: fieldName)
        }

        guard let normalizedInput = normalizeDecimalString(trimmed) else {
            throw ParseError.invalidDecimalString(field: fieldName)
        }

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
    /// without rounding or losing significant digits.
    public static func normalizeDecimalString(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var s = trimmed
        var isNegative = false
        if s.hasPrefix("-") {
            isNegative = true
            s.removeFirst()
        } else if s.hasPrefix("+") {
            s.removeFirst()
        }

        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }

        var intPart = String(parts[0])
        var fracPart = parts.count == 2 ? String(parts[1]) : ""

        // Every character must be an ASCII digit
        guard intPart.allSatisfy({ $0 >= "0" && $0 <= "9" }) &&
              fracPart.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        guard !intPart.isEmpty || !fracPart.isEmpty else { return nil }
        if intPart.isEmpty { intPart = "0" }

        // Strip leading zeros in integer part
        while intPart.count > 1 && intPart.hasPrefix("0") {
            intPart.removeFirst()
        }

        // Strip trailing zeros in fraction part
        while fracPart.hasSuffix("0") {
            fracPart.removeLast()
        }

        if intPart == "0" && fracPart.isEmpty {
            return "0"
        }

        let sign = isNegative ? "-" : ""
        if fracPart.isEmpty {
            return "\(sign)\(intPart)"
        } else {
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
