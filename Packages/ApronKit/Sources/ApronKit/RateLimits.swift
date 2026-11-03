import Foundation

/// What a wait the server asked for (§1.1 `retry_after`) holds back, as apron-web's `LimitScope`:
/// pages of history and room listings (`ext:limits` `read`), sending, every write (`ext:limits`
/// `write`), or messages with new files (`ext:limits` `upload`).
public enum LimitScope: String, Hashable, Sendable, CaseIterable {
    case history, message, write, upload

    /// The requests an `ext:limits` `write` wait holds back: posting, reacting, joining, leaving
    /// and room changes. Not `command`, which may do anything, nor `me`.
    static let writes: Set<String> = ["message", "reactions", "room_join", "room_leave", "room_set"]

    /// What a request refused with `retry_after` holds back, as apron-web's `limitScope`. With
    /// `ext:limits`, a `write` category on a write holds back every write, and an `upload` one on
    /// a request adding an upload holds back those that do. Otherwise only further `history` or
    /// `message` requests wait; any other refusal fails just its request.
    public init?(refused method: String, params: JSONValue?, category: String?) {
        if category == "write", Self.writes.contains(method) {
            self = .write
        } else if category == "upload", Self.addsUpload(method, params) {
            self = .upload
        } else if category == "read", method == "room_list" {
            self = .history
        } else if let scope = LimitScope(rawValue: method), scope == .history || scope == .message {
            self = scope
        } else {
            return nil
        }
    }

    /// Whether a wait on this scope refuses `method` before it is sent.
    public func holds(_ method: String, params: JSONValue?) -> Bool {
        switch self {
        case .write: Self.writes.contains(method)
        case .upload: Self.addsUpload(method, params)
        case .message: method == "message"
        case .history: method == "history" || method == "room_list"
        }
    }

    /// A `message` or `command` with an `upload` embed without an `embed_id`: a new file (§4.8.2).
    static func addsUpload(_ method: String, _ params: JSONValue?) -> Bool {
        guard method == "message" || method == "command" else { return false }
        return (params?["body"]?["embeds"]?.arrayValue ?? []).contains {
            $0["kind"]?.stringValue == "upload" && $0["embed_id"] == nil
        }
    }
}

/// A `retry_after` (§1.1) short enough to wait out at the request rather than show: a page of
/// history, a room listing, a reaction or an edit is sent again under its `id` once the wait is
/// over. A post is not: the outbox keeps its own retries and its Not sent state.
public enum ShortWait {
    /// The longest wait waited out. aprond's limits refill one request in 60 s over the rate a
    /// minute: a history page in 3 s at its 20 a minute, 1 s at an address's 60; a room listing
    /// at its 6 a minute takes 10 s, and so shows, as every longer wait does.
    public static let longest: Duration = .seconds(5)
    /// Sends after the first. One refill lets the first resend in; the second covers another
    /// request taking that place first. At most 10 s more, each send with its own timeout.
    public static let resends = 2

    /// The requests a short wait is waited out for: `history`, `room_list`, `reactions`, and a
    /// `message` naming its `message_id` (an edit, move or delete), never a post.
    public static func waitsOut(_ method: String, _ params: JSONValue?) -> Bool {
        switch method {
        case "history", "room_list", "reactions": true
        case "message": params?["message_id"] != nil
        default: false
        }
    }
}

/// A wait the server asked for: when it is over, the server's words, and when it began, which
/// decides whether it counts down in seconds or in minutes.
public struct LimitWait: Hashable, Sendable {
    public var until: Date
    public var since: Date
    public var message: String

    /// A wait of an hour or more in all counts down in minutes and can be put away.
    public var isLong: Bool { until.timeIntervalSince(since) >= WaitWords.long }
}

/// How a wait reads, as apron-web's `waitLabel`, `waitWords`, `retryAfterLabel` and
/// RateLimitNotice.
public enum WaitWords {
    /// An hour: a wait this long counts down in minutes, with a clock.
    public static let long: TimeInterval = 3600

    /// Time left as a countdown shows it: `17s` under a minute, then `m:ss`; a long wait in whole
    /// minutes, `3h 12m`, rounded up so it never reads 0 before it is over.
    public static func countdown(_ left: TimeInterval, long: Bool) -> String {
        if long {
            let minutes = max(1, Int((left / 60).rounded(.up)))
            return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        }
        let seconds = max(0, Int(left.rounded(.up)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    /// The countdown in words, for VoiceOver: `17 seconds`, `3 hours 12 minutes`.
    public static func spoken(_ left: TimeInterval, long: Bool) -> String {
        func unit(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
        if !long, left < 60 { return unit(max(1, Int(left.rounded(.up))), "second") }
        let minutes = max(1, Int((left / 60).rounded(.up)))
        let hours = minutes / 60
        guard hours > 0 else { return unit(minutes, "minute") }
        return ([unit(hours, "hour")] + (minutes % 60 > 0 ? [unit(minutes % 60, "minute")] : [])).joined(separator: " ")
    }

    /// `45s`, `3m`, `2h`: a refused request's wait, as its error says it.
    public static func retryAfter(_ wait: TimeInterval) -> String {
        let seconds = max(1, Int(wait.rounded(.up)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        if minutes < 60 { return "\(minutes)m" }
        return "\(Int((Double(minutes) / 60).rounded(.up)))h"
    }

    /// A server's sentence, ending in `.` unless it ends in `.`, `!`, `?` or `…` already.
    public static func punctuated(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?…".contains(last) else { return trimmed }
        return trimmed + "."
    }

    /// The notice over the composer: what waits, then the time left. Nil for history, which waits
    /// where it loads.
    public static func notice(_ scope: LimitScope) -> (title: String, lead: String, end: String)? {
        switch scope {
        case .message, .write: ("Sending is paused.", "You can send again in", ".")
        case .upload: ("Uploads are paused.", "Uploads resume in", ".")
        case .history: nil
        }
    }
}

extension RPCError {
    /// What the user reads of a refusal, as apron-web's `userFacingRpcError`: a `retry_after`
    /// adds when to try again ("Slow down. Try again in 45s.").
    public var userFacing: String {
        if let wait = retryAfter {
            let words = message.isEmpty ? "Temporarily limited" : message
            return "\(WaitWords.punctuated(words)) Try again in \(WaitWords.retryAfter(Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18))."
        }
        return message.isEmpty ? "Request failed (\(code))." : message
    }
}
