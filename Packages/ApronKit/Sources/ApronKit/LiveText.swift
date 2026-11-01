import Foundation

/// Reading live text (v10 §4.8.5): the `url` of an `append` or `terminal` embed while it is
/// live, as apron-web's `live-text.ts`. `GET url` returns the text the server kept, from its
/// start, then more as it arrives, and ends when the text ends. A reader that reconnects
/// replaces what it showed with the new response.
public enum LiveTextEvent: Sendable, Equatable {
    /// A response began: it replaces whatever was shown, from the start of the text.
    case started
    /// The next bytes, as they arrived: UTF-8, maybe cut inside a character.
    case bytes(Data)
}

/// One `GET url`: `started`, then the bytes, finishing when the text ends; it throws
/// `LiveTextRefused` for a status other than 200, or the transport's error when it drops.
public typealias LiveTextRead = @Sendable (URL) -> AsyncThrowingStream<LiveTextEvent, any Error>

/// A `GET url` the server answered with a status other than OK.
public struct LiveTextRefused: Error, Equatable, Sendable {
    public var status: Int
    /// A 429's `Retry-After`, in seconds.
    public var retryAfter: Int?

    public init(status: Int, retryAfter: Int? = nil) {
        self.status = status
        self.retryAfter = retryAfter
    }

    /// An answer trying again would not change, as apron-web's `definitive`: a 4xx other than
    /// 408 and 429, such as an ended text's 404 or a spent read budget's 403. Each try may count
    /// against the server's limits, so a reader that kept trying could lock itself out.
    public var isDefinitive: Bool { (400..<500).contains(status) && status != 408 && status != 429 }
}

public enum LiveTextFollow {
    /// The pauses before trying again after a failure or a drop, the last repeated (apron-web's
    /// `LIVE_RETRY_MS`).
    public static let retry: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]

    /// Follows live text until it ends or the task is cancelled, as apron-web's
    /// `followLiveText`: after a failure or a drop it tries again, waiting longer each time
    /// (never less than a 429's `Retry-After`), and the new response replaces what was shown;
    /// a definitive refusal ends it as the text's end does. `ended` is called once either way,
    /// not on cancellation.
    @MainActor
    public static func run(_ url: URL, read: LiveTextRead, sleep: @Sendable (Duration) async throws -> Void,
                           started: () -> Void, bytes: (Data) -> Void, ended: () -> Void) async {
        var failures = 0
        while !Task.isCancelled {
            var began = false
            do {
                for try await event in read(url) {
                    switch event {
                    case .started:
                        began = true
                        started()
                    case .bytes(let data):
                        bytes(data)
                    }
                }
                if Task.isCancelled { return }
                ended()
                return
            } catch {
                if Task.isCancelled { return }
                let refused = error as? LiveTextRefused
                if refused?.isDefinitive == true {
                    ended()
                    return
                }
                failures = began ? 1 : failures + 1
                var wait = retry[min(failures, retry.count) - 1]
                if let seconds = refused?.retryAfter { wait = max(wait, .seconds(seconds)) }
                do { try await sleep(wait) } catch { return }
            }
        }
    }
}

/// A decoder for live text's bytes, as the server converts the text it keeps (§4.8.5): the
/// WHATWG UTF-8 decode without BOM, so each invalid sequence reads as one U+FFFD and a leading
/// BOM stays. A character cut between chunks is held until the rest comes; `finish` flushes
/// what is held at the end of a response.
public struct LiveTextDecoder: Sendable {
    private var held: [UInt8] = []

    public init() {}

    public mutating func decode(_ data: Data) -> String {
        let bytes = held + data
        let cut = Self.completeEnd(bytes)
        held = Array(bytes[cut...])
        return String(decoding: bytes[..<cut], as: UTF8.self)
    }

    public mutating func finish() -> String {
        defer { held = [] }
        return held.isEmpty ? "" : String(decoding: held, as: UTF8.self)
    }

    /// Where the bytes stop being whole: before a last sequence that is a valid start of a
    /// character but needs more bytes.
    static func completeEnd(_ bytes: [UInt8]) -> Int {
        let end = bytes.count
        for back in 1...min(3, end) {
            let start = end - back
            let lead = bytes[start]
            if lead & 0xC0 == 0x80 { continue }
            let length = lead >= 0xF0 && lead <= 0xF4 ? 4 : lead >= 0xE0 && lead <= 0xEF ? 3 : lead >= 0xC2 && lead <= 0xDF ? 2 : 1
            guard length > back else { return end }
            if back >= 2 {
                let second = bytes[start + 1]
                let allowed: ClosedRange<UInt8> = switch lead {
                case 0xE0: 0xA0...0xBF
                case 0xED: 0x80...0x9F
                case 0xF0: 0x90...0xBF
                case 0xF4: 0x80...0x8F
                default: 0x80...0xBF
                }
                guard allowed.contains(second) else { return end }
            }
            return start
        }
        return end
    }
}

/// An `append` embed's edits (§4.8.5), as apron-web's `editLiveText`: in `added`, the next
/// decoded text, U+0008 removes the code point before it and U+000C all the text before it.
/// They reach only the live text, never `body.text`, which the caller keeps apart, and text
/// already edited passes through unchanged. The cost is `added`'s length and what it removes.
/// Not for `terminal` embeds, where both are the terminal's own.
public enum LiveTextEdit {
    public static func apply(_ added: String, to kept: inout String) {
        var added = Substring(added)
        if let feed = added.lastIndex(of: "\u{0C}") {
            kept = ""
            added = added[added.index(after: feed)...]
        }
        guard added.contains("\u{08}") else {
            kept += added
            return
        }
        for scalar in added.unicodeScalars {
            if scalar == "\u{08}" {
                if !kept.unicodeScalars.isEmpty { kept.unicodeScalars.removeLast() }
            } else {
                kept.unicodeScalars.append(scalar)
            }
        }
    }
}

/// Markdown still arriving, settled for display only, as apron-web's `settleMarkdown`: an open
/// code fence is closed, and in the last paragraph an open code span and an odd `**` or `~~`
/// are closed after the text so far (or held back with nothing after them); a link whose
/// destination has not closed shows as its label, an unclosed `[` as its text, and a last line
/// that is only a list marker or a setext underline waits.
public enum LiveMarkdown {
    public static func settle(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var fence: (char: Character, length: Int)?
        var paragraph = 0
        for (index, line) in lines.enumerated() {
            let match = fenceMatch(line)
            if let open = fence {
                if let match, match.run.first == open.char, match.run.count >= open.length, match.info.trimmingCharacters(in: .whitespaces).isEmpty {
                    fence = nil
                    paragraph = index + 1
                }
                continue
            }
            if let match, !(match.run.first == "`" && match.info.contains("`")) {
                fence = (match.run.first!, match.run.count)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { paragraph = index + 1 }
        }
        if let fence { return text + (text.hasSuffix("\n") ? "" : "\n") + String(repeating: fence.char, count: fence.length) }
        if paragraph >= lines.count { return text }
        let head = lines[..<paragraph]
        let tail = settleParagraph(lines[paragraph...].joined(separator: "\n"))
        return (head + [tail]).joined(separator: "\n")
    }

    /// ` {0,3}(`{3,}|~{3,})(.*)`.
    private static func fenceMatch(_ line: String) -> (run: String, info: String)? {
        let indent = line.prefix { $0 == " " }
        guard indent.count <= 3 else { return nil }
        let rest = line.dropFirst(indent.count)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        return (String(run), String(rest.dropFirst(run.count)))
    }

    private static func settleParagraph(_ text: String) -> String {
        var tail = holdBackLastLine(text)
        if let span = openCodeSpan(tail) {
            let after = tail.utf16.index(tail.utf16.startIndex, offsetBy: span.at + span.run.utf16.count)
            let before = tail.utf16.index(tail.utf16.startIndex, offsetBy: span.at)
            if !tail[after...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return trimEnd(tail) + span.run
            }
            return String(tail[..<before])
        }
        tail = holdBackLink(tail)
        var open: [(mark: String, at: Int)] = []
        for mark in ["~~", "**"] {
            guard let at = unmatched(withoutCodeSpans(tail), mark) else { continue }
            let utf16 = Array(tail.utf16)
            let after = String(decoding: utf16[(at + 2)...], as: UTF16.self)
            if after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tail = String(decoding: utf16[..<at] + utf16[(at + 2)...], as: UTF16.self)
            } else {
                open.append((mark, at))
            }
        }
        let closers = open.sorted { $0.at > $1.at }.map(\.mark).joined()
        return closers.isEmpty ? tail : trimEnd(tail) + closers
    }

    private static func trimEnd(_ text: String) -> String {
        var text = Substring(text)
        while let last = text.last, last.isWhitespace { text = text.dropLast() }
        return String(text)
    }

    private static func holdBackLastLine(_ text: String) -> String {
        let cut = text.lastIndex(of: "\n")
        let last = cut.map { String(text[text.index(after: $0)...]) } ?? text
        guard !last.trimmingCharacters(in: .whitespaces).isEmpty,
              last.wholeMatch(of: /^ {0,3}(?:[-*+]|\d{1,9}[.)]|[-=]+)\s*$/) != nil else { return text }
        return cut.map { String(text[..<$0]) } ?? ""
    }

    private static func holdBackLink(_ text: String) -> String {
        if let destination = text.firstMatch(of: /(!?)\[([^\]\n]*)\]\([^)\n]*$/) {
            return String(text[..<destination.range.lowerBound]) + (destination.output.1.isEmpty ? String(destination.output.2) : "")
        }
        if let label = text.firstMatch(of: /(!?)\[([^\]\n]*)$/) {
            return String(text[..<label.range.lowerBound]) + (label.output.1.isEmpty ? String(label.output.2) : "")
        }
        return text
    }

    /// The last code span left open: its UTF-16 offset and the run that opened it.
    private static func openCodeSpan(_ text: String) -> (at: Int, run: String)? {
        var open: (at: Int, run: String)?
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            guard units[index] == 0x60, index == 0 || units[index - 1] != 0x5C else { index += 1; continue }
            var end = index
            while end < units.count, units[end] == 0x60 { end += 1 }
            let run = String(repeating: "`", count: end - index)
            if open == nil { open = (index, run) } else if open?.run == run { open = nil }
            index = end
        }
        return open
    }

    /// The text with its closed code spans blanked, every UTF-16 offset kept.
    private static func withoutCodeSpans(_ text: String) -> String {
        var units = Array(text.utf16)
        var index = 0
        while index < units.count {
            guard units[index] == 0x60, index == 0 || units[index - 1] != 0x5C else { index += 1; continue }
            var end = index
            while end < units.count, units[end] == 0x60 { end += 1 }
            let length = end - index
            var search = end
            var closed: Int?
            while search < units.count {
                if units[search] == 0x60 {
                    var close = search
                    while close < units.count, units[close] == 0x60 { close += 1 }
                    if close - search == length, search > end { closed = close; break }
                    search = close
                } else {
                    search += 1
                }
            }
            if let closed {
                for i in index..<closed { units[i] = 0x20 }
                index = closed
            } else {
                index = end
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// The UTF-16 offset of the last of an odd number of unescaped `mark`s.
    private static func unmatched(_ text: String, _ mark: String) -> Int? {
        let units = Array(text.utf16)
        let markUnits = Array(mark.utf16)
        var found: [Int] = []
        var index = 0
        while index + markUnits.count <= units.count {
            if Array(units[index..<(index + markUnits.count)]) == markUnits, index == 0 || units[index - 1] != 0x5C {
                found.append(index)
                index += markUnits.count
            } else {
                index += 1
            }
        }
        return found.count % 2 == 1 ? found.last : nil
    }
}

/// How much of a terminal's text a reader keeps, in UTF-16 units as apron-web's
/// `TERMINAL_FEED_KEEP`: about 256 KiB, more than servers keep, cut once it passes that by a
/// quarter, from its first control character (the server's `keep_last`, §4.8.6).
public enum TerminalFeed {
    public static let keep = 256 * 1024

    public static func keepLast(_ text: String, limit: Int = keep) -> String {
        let units = text.utf16
        guard units.count > limit else { return text }
        let tail = text.utf16.suffix(limit)
        if let control = tail.firstIndex(where: { $0 < 0x20 }) { return String(text[control...]) }
        var start = tail.startIndex
        if let unit = tail.first, (0xDC00...0xDFFF).contains(unit) { start = text.utf16.index(after: start) }
        return String(text[start...])
    }
}

/// `LiveTextRead` over URLSession: an ephemeral session, no cookies or credentials, nothing
/// cached, each chunk as it arrives.
public enum LiveTextFetch {
    public static let live: LiveTextRead = { url in
        AsyncThrowingStream { continuation in
            let reader = StreamingReader(continuation: continuation)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 300)
            request.httpShouldHandleCookies = false
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 300
            let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    private final class StreamingReader: NSObject, URLSessionDataDelegate, Sendable {
        let continuation: AsyncThrowingStream<LiveTextEvent, any Error>.Continuation

        init(continuation: AsyncThrowingStream<LiveTextEvent, any Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
            let http = response as? HTTPURLResponse
            guard let http, http.statusCode == 200 else {
                let status = http?.statusCode ?? 0
                continuation.finish(throwing: LiveTextRefused(status: status, retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }))
                return .cancel
            }
            continuation.yield(.started)
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(.bytes(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            session.finishTasksAndInvalidate()
        }
    }
}
