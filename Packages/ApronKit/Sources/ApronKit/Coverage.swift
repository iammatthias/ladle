/// A closed range of log positions (§2.1), `lower` through `upper`, every record of which a client
/// holds. A `history` page's bounds are inclusive (§4.3.2), so a page is a span.
public struct LogSpan: Hashable, Sendable, Comparable {
    public var lower: LogID
    public var upper: LogID

    public init(_ lower: LogID, _ upper: LogID) {
        self.lower = min(lower, upper)
        self.upper = max(lower, upper)
    }

    public func holds(_ position: LogID) -> Bool { lower <= position && position <= upper }

    /// How many positions it covers; a count of records only where every position is a record.
    public var count: Int { Int(upper.number - lower.number) + 1 }

    /// Whether the two overlap or sit side by side, so one span holds both.
    func touches(_ other: LogSpan) -> Bool {
        lower.number <= other.upper.number + 1 && other.lower.number <= upper.number + 1
    }

    public static func < (lhs: LogSpan, rhs: LogSpan) -> Bool { lhs.lower < rhs.lower }
}

/// The spans of one room's log a client holds, ascending, disjoint and never side by side (two
/// that touch are one). The positions between two neighbours are a hole: records the server has
/// that the client has not loaded, loadable from either side. One flat sorted array; a room has a
/// handful of spans at most, so every read walks it.
public struct Coverage: Hashable, Sendable {
    public private(set) var spans: [LogSpan] = []

    public init() {}

    public init(_ spans: [LogSpan]) {
        for span in spans { insert(span) }
    }

    public var isEmpty: Bool { spans.isEmpty }
    public var oldest: LogSpan? { spans.first }
    public var newest: LogSpan? { spans.last }

    /// The holes between neighbouring spans, ascending.
    public var holes: [LogSpan] {
        zip(spans, spans.dropFirst()).map { below, above in LogSpan(below.upper.successor!, above.lower.predecessor!) }
    }

    /// Adds a span, merging it with every span it overlaps or touches.
    public mutating func insert(_ span: LogSpan) {
        var merged = span
        var kept: [LogSpan] = []
        kept.reserveCapacity(spans.count + 1)
        var placed = false
        for existing in spans {
            if existing.touches(merged) {
                merged = LogSpan(min(existing.lower, merged.lower), max(existing.upper, merged.upper))
            } else {
                if !placed, merged.upper < existing.lower {
                    kept.append(merged)
                    placed = true
                }
                kept.append(existing)
            }
        }
        if !placed { kept.append(merged) }
        spans = kept
    }

    public func index(holding position: LogID) -> Int? { spans.firstIndex { $0.holds(position) } }

    public func holds(_ position: LogID) -> Bool { index(holding: position) != nil }

    /// The lowest span wholly above a position, whose lower edge bounds a page up from there.
    public func span(above position: LogID) -> LogSpan? { spans.first { $0.lower > position } }

    /// Lets go of what lies below `floor`: the server has expired it (§4.3.3).
    public mutating func dropBelow(_ floor: LogID) {
        spans.removeAll { $0.upper < floor }
        if let first = spans.first, first.lower < floor { spans[0].lower = floor }
    }

    /// Moves the newest span's upper edge up to `position`, as a live record or a catch-up page
    /// completes the room through there. Nothing without a span.
    public mutating func advance(to position: LogID) {
        guard let last = spans.indices.last, spans[last].upper < position else { return }
        spans[last].upper = position
    }
}

extension LogID {
    var number: UInt64 { UInt64(text)! }
}
