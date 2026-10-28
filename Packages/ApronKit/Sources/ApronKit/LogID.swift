/// A log position (§2.1) or a message identity (§2.2): a positive decimal below 2^53, carried as a
/// string and compared as a number. Keeping the text avoids any float conversion.
public struct LogID: Hashable, Sendable, CustomStringConvertible {
    public let text: String

    /// Accepts `^[1-9][0-9]{0,15}$` below 2^53, the same rule the reference client applies.
    public init?(_ text: String) {
        let bytes = Array(text.utf8)
        guard (1 ... 16).contains(bytes.count), bytes[0] != UInt8(ascii: "0"),
              bytes.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }),
              let value = UInt64(text), value < 1 << 53
        else { return nil }
        self.text = text
    }

    public init?(_ value: JSONValue?) {
        guard let text = value?.stringValue else { return nil }
        self.init(text)
    }

    public var description: String { text }
    public var json: JSONValue { .string(text) }
}

extension LogID: Comparable {
    public static func < (lhs: LogID, rhs: LogID) -> Bool {
        if lhs.text.utf8.count != rhs.text.utf8.count { return lhs.text.utf8.count < rhs.text.utf8.count }
        return lhs.text < rhs.text
    }
}

/// `room_id`, `user_id`, and request `id` (§2.4): any non-empty string without whitespace or
/// control characters.
enum OpaqueID {
    static func isValid(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { scalar in
            scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
        }
    }

    static func validated(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue, isValid(text) else { return nil }
        return text
    }
}
