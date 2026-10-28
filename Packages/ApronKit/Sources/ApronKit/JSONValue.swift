import Foundation

/// A JSON document exactly as the wire carries it.
///
/// Numbers keep their source text, so IDs and `ext` values beyond 2^53 round-trip untouched.
/// Object keys are kept exactly, "__proto__" and "constructor" included; a duplicate key keeps
/// its last value. Objects compare without regard to key order, which is what the protocol's
/// fixtures require. Foundation's JSON types can do none of this, hence the hand-written codec.
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Accessors

extension JSONValue {
    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// The number as an `Int` when its text is an integer in range; nil for other numbers.
    public var intValue: Int? {
        if case .number(let text) = self { return Int(text) }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let text) = self { return Double(text) }
        return nil
    }

    public var isNull: Bool { self == .null }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(String(value)) }
    public init(floatLiteral value: Double) { self = .number(String(value)) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var members: [String: JSONValue] = [:]
        for (key, value) in elements { members[key] = value }
        self = .object(members)
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "JSON parse error at byte \(offset): \(reason)" }
}

extension JSONValue {
    public init(parsing text: String) throws {
        try self.init(parsing: Array(text.utf8))
    }

    public init(parsing data: Data) throws {
        try self.init(parsing: [UInt8](data))
    }

    public init(parsing bytes: [UInt8]) throws {
        var parser = Parser(bytes: bytes)
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.atEnd else { throw parser.error("trailing characters") }
        self = value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }

        func error(_ reason: String) -> JSONParseError {
            JSONParseError(offset: index, reason: reason)
        }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        mutating func parseValue() throws -> JSONValue {
            guard index < bytes.count else { throw error("unexpected end of input") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
            case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
            case UInt8(ascii: "n"): try expectLiteral("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
            default: throw error("unexpected character")
            }
        }

        mutating func expectLiteral(_ literal: StaticString) throws {
            let expected = Array(literal.description.utf8)
            guard bytes.count - index >= expected.count,
                  Array(bytes[index ..< index + expected.count]) == expected
            else { throw error("invalid literal") }
            index += expected.count
        }

        mutating func parseObject() throws -> JSONValue {
            index += 1
            var members: [String: JSONValue] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected object key") }
                let key = try parseString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
                index += 1
                skipWhitespace()
                members[key] = try parseValue()
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated object") }
                switch bytes[index] {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "}"): index += 1; return .object(members)
                default: throw error("expected ',' or '}'")
                }
            }
        }

        mutating func parseArray() throws -> JSONValue {
            index += 1
            var elements: [JSONValue] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(elements)
            }
            while true {
                skipWhitespace()
                elements.append(try parseValue())
                skipWhitespace()
                guard index < bytes.count else { throw error("unterminated array") }
                switch bytes[index] {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "]"): index += 1; return .array(elements)
                default: throw error("expected ',' or ']'")
                }
            }
        }

        mutating func parseNumber() throws -> String {
            let start = index
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid number") }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid fraction") }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid exponent") }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            return String(decoding: bytes[start ..< index], as: UTF8.self)
        }

        private func isDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
        }

        mutating func parseString() throws -> String {
            index += 1
            var out: [UInt8] = []
            while true {
                guard index < bytes.count else { throw error("unterminated string") }
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    return String(decoding: out, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    index += 1
                    guard index < bytes.count else { throw error("unterminated escape") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = UInt32(try parseHex4())
                        if (0xD800 ... 0xDBFF).contains(scalar) {
                            if bytes.count - index >= 6, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                                let save = index
                                index += 2
                                let low = UInt32(try parseHex4())
                                if (0xDC00 ... 0xDFFF).contains(low) {
                                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                                } else {
                                    index = save
                                    scalar = 0xFFFD
                                }
                            } else {
                                scalar = 0xFFFD
                            }
                        } else if (0xDC00 ... 0xDFFF).contains(scalar) {
                            scalar = 0xFFFD
                        }
                        out.append(contentsOf: Array(String(UnicodeScalar(scalar) ?? "\u{FFFD}").utf8))
                    default:
                        throw error("invalid escape")
                    }
                case 0x00 ... 0x1F:
                    throw error("control character in string")
                default:
                    out.append(byte)
                    index += 1
                }
            }
        }

        mutating func parseHex4() throws -> UInt16 {
            guard bytes.count - index >= 4 else { throw error("short \\u escape") }
            var value: UInt16 = 0
            for _ in 0 ..< 4 {
                let byte = bytes[index]
                let digit: UInt16
                switch byte {
                case UInt8(ascii: "0") ... UInt8(ascii: "9"): digit = UInt16(byte - UInt8(ascii: "0"))
                case UInt8(ascii: "a") ... UInt8(ascii: "f"): digit = UInt16(byte - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A") ... UInt8(ascii: "F"): digit = UInt16(byte - UInt8(ascii: "A") + 10)
                default: throw error("invalid hex digit")
                }
                value = value << 4 | digit
                index += 1
            }
            return value
        }
    }
}

// MARK: - Serializing

extension JSONValue {
    /// Compact JSON with object keys in code point order, so equal values serialize identically.
    public func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    public func serializedData() -> Data {
        Data(serialized().utf8)
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .number(let text):
            out += text
        case .string(let value):
            JSONValue.writeString(value, into: &out)
        case .array(let elements):
            out += "["
            for (offset, element) in elements.enumerated() {
                if offset > 0 { out += "," }
                element.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (offset, key) in members.keys.sorted(by: codePointLess).enumerated() {
                if offset > 0 { out += "," }
                JSONValue.writeString(key, into: &out)
                out += ":"
                members[key]!.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{00}" ... "\u{1F}":
                out += "\\u" + String(format: "%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

// MARK: - String order

/// Unicode code point order, which the protocol calls "string order". Swift's `<` on `String`
/// compares canonical equivalents, which is not the same relation.
public func codePointLess(_ left: String, _ right: String) -> Bool {
    var l = left.unicodeScalars.makeIterator()
    var r = right.unicodeScalars.makeIterator()
    while true {
        switch (l.next(), r.next()) {
        case (nil, nil): return false
        case (nil, _): return true
        case (_, nil): return false
        case (let a?, let b?):
            if a.value != b.value { return a.value < b.value }
        }
    }
}
