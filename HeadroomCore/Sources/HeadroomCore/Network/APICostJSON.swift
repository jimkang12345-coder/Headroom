import Foundation

/// A bounded JSON reader that retains monetary number lexemes instead of converting via Double.
/// Duplicate object keys are rejected so amount/currency fields cannot be ambiguous.
indirect enum APICostJSON {
    case object([String: APICostJSON])
    case array([APICostJSON])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    func field(_ key: String) throws -> APICostJSON {
        guard case .object(let object) = self, let value = object[key] else {
            throw APICostError.malformedResponse
        }
        return value
    }

    var values: [APICostJSON] {
        get throws {
            guard case .array(let values) = self else { throw APICostError.malformedResponse }
            return values
        }
    }

    var text: String {
        get throws {
            guard case .string(let value) = self else { throw APICostError.malformedResponse }
            return value
        }
    }

    var integer: Int64 {
        get throws {
            guard case .number(let raw) = self, raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let value = Int64(raw) else { throw APICostError.malformedResponse }
            return value
        }
    }

    static func parse(_ data: Data) throws -> APICostJSON {
        var reader = Reader(bytes: Array(data))
        let value = try reader.value(depth: 0)
        reader.skipWhitespace()
        guard reader.index == reader.bytes.count else { throw APICostError.malformedResponse }
        return value
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0

        mutating func skipWhitespace() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func value(depth: Int) throws -> APICostJSON {
            nodes += 1
            guard depth <= 16, nodes <= 20_000 else { throw APICostError.malformedResponse }
            skipWhitespace()
            guard index < bytes.count else { throw APICostError.malformedResponse }
            switch bytes[index] {
            case 123:
                index += 1
                var object: [String: APICostJSON] = [:]
                if consume(125) { return .object(object) }
                repeat {
                    let key = try string()
                    guard object[key] == nil, consume(58) else { throw APICostError.malformedResponse }
                    object[key] = try value(depth: depth + 1)
                    if consume(125) { return .object(object) }
                    guard consume(44) else { throw APICostError.malformedResponse }
                } while true
            case 91:
                index += 1
                var array: [APICostJSON] = []
                if consume(93) { return .array(array) }
                repeat {
                    array.append(try value(depth: depth + 1))
                    if consume(93) { return .array(array) }
                    guard consume(44) else { throw APICostError.malformedResponse }
                } while true
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func string() throws -> String {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 34 else { throw APICostError.malformedResponse }
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 92 {
                    guard index < bytes.count else { throw APICostError.malformedResponse }
                    index += 1
                } else if byte == 34 {
                    do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                    catch { throw APICostError.malformedResponse }
                }
            }
            throw APICostError.malformedResponse
        }

        mutating func literal(_ raw: String) throws {
            let literal = Array(raw.utf8)
            guard index + literal.count <= bytes.count,
                  Array(bytes[index..<(index + literal.count)]) == literal else {
                throw APICostError.malformedResponse
            }
            index += literal.count
        }

        mutating func number() throws -> String {
            let start = index
            if index < bytes.count, bytes[index] == 45 { index += 1 }
            guard index < bytes.count else { throw APICostError.malformedResponse }
            if bytes[index] == 48 { index += 1 }
            else {
                guard (49...57).contains(bytes[index]) else { throw APICostError.malformedResponse }
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                let fraction = index
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                guard index > fraction else { throw APICostError.malformedResponse }
            }
            if index < bytes.count, bytes[index] == 69 || bytes[index] == 101 {
                index += 1
                if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
                let exponent = index
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                guard index > exponent else { throw APICostError.malformedResponse }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}

enum APICostMoney {
    static func decimal(_ raw: String, allowExponent: Bool) throws -> Decimal {
        guard raw.utf8.count <= 160, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.hasPrefix("+") else { throw APICostError.malformedResponse }
        let lower = raw.lowercased()
        let parts = lower.split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.count == 1 || allowExponent else { throw APICostError.malformedResponse }
        var expanded = String(parts[0])
        if parts.count == 2 {
            guard let exponent = Int(parts[1]), (-128...128).contains(exponent) else { throw APICostError.malformedResponse }
            let negative = expanded.hasPrefix("-")
            if negative { expanded.removeFirst() }
            let mantissa = expanded.split(separator: ".", omittingEmptySubsequences: false)
            guard mantissa.count <= 2 else { throw APICostError.malformedResponse }
            let digits = mantissa.joined()
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw APICostError.malformedResponse
            }
            let decimalIndex = mantissa[0].count + exponent
            if decimalIndex <= 0 { expanded = "0." + String(repeating: "0", count: -decimalIndex) + digits }
            else if decimalIndex >= digits.count { expanded = digits + String(repeating: "0", count: decimalIndex - digits.count) }
            else {
                let split = digits.index(digits.startIndex, offsetBy: decimalIndex)
                expanded = String(digits[..<split]) + "." + String(digits[split...])
            }
            if negative { expanded = "-" + expanded }
        }
        do { return try CurrencyBalance.parseDecimalStrict(expanded, fieldName: "reported_cost") }
        catch { throw APICostError.malformedResponse }
    }

    static func add(_ value: Decimal, to total: inout Decimal) throws {
        var left = total
        var right = value
        var sum = Decimal()
        guard NSDecimalAdd(&sum, &left, &right, .plain) == .noError, !sum.isNaN else {
            throw APICostError.malformedResponse
        }
        total = sum
    }

    static func dollars(fromCents value: Decimal) throws -> Decimal {
        var cents = value
        var divisor = Decimal(100)
        var dollars = Decimal()
        guard NSDecimalDivide(&dollars, &cents, &divisor, .plain) == .noError, !dollars.isNaN else {
            throw APICostError.malformedResponse
        }
        return dollars
    }
}
