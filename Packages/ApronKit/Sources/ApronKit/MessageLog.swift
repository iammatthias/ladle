import Foundation

/// Messages as a readable Markdown log, for the pasteboard ("Copy as Markdown log"), as
/// apron-web's `messageLog` (#164, #168, #172). Each sender's run is one block quote, opened by
/// their name in bold and the time: the first with the full date (`Friday, Oct 30, 2026 at
/// 2:02 PM`) as an anchor, and the day again wherever it changes. Consecutive messages from one
/// sender within five minutes share a quote, as the timeline groups them. A reply opens with a
/// one-line quote of what it answers (`> ↪ **Ada**: Deploy is green…`). A message with
/// reactions heads a quote of its own, its header listing them, and so does the message after
/// it. Where the log skips messages of `order`, a line between the quotes says how many. Bodies
/// are copied as written, with each uploaded image after as a Markdown image.
public enum MessageLog {
    /// One emoji's reactions on a message: the names of those the app can name, and how many
    /// reacted in all, so the rest are counted.
    public struct Reaction: Hashable, Sendable {
        public var emoji: String
        public var names: [String]
        public var count: Int

        public init(emoji: String, names: [String], count: Int) {
            self.emoji = emoji
            self.names = names
            self.count = count
        }
    }

    public struct Options {
        /// The name shown for a message's sender.
        public var nameOf: (MessageSnapshot) -> String
        /// A message a reply answers when it isn't in the log itself, if this client has it.
        public var lookup: (LogID) -> MessageSnapshot?
        /// Which year is "this year", so a later date leaves it out.
        public var now: Date
        /// A message's reactions, listed after its sender's name.
        public var reactions: (MessageSnapshot) -> [Reaction]?
        /// Every message's ID in the conversation, in order, so a gap between two in the log
        /// can say how many it leaves out.
        public var order: [LogID]?
        /// Days, years and the formats' locale and time zone.
        public var calendar: Calendar

        public init(
            nameOf: @escaping (MessageSnapshot) -> String,
            lookup: @escaping (LogID) -> MessageSnapshot? = { _ in nil },
            now: Date = Date(),
            reactions: @escaping (MessageSnapshot) -> [Reaction]? = { _ in nil },
            order: [LogID]? = nil,
            calendar: Calendar = .autoupdatingCurrent
        ) {
            self.nameOf = nameOf
            self.lookup = lookup
            self.now = now
            self.reactions = reactions
            self.order = order
            self.calendar = calendar
        }
    }

    /// The log of `messages`, taken in the order given, each once: where one comes more than
    /// once (edited, or an upload finishing), its latest snapshot by `log_id` stands where it
    /// first came. Empty for no messages.
    public static func markdown(_ messages: [MessageSnapshot], options: Options) -> String {
        var ids: [LogID] = []
        var byID: [LogID: MessageSnapshot] = [:]
        for message in messages {
            if let kept = byID[message.messageID] {
                if message.logID >= kept.logID { byID[message.messageID] = message }
            } else {
                ids.append(message.messageID)
                byID[message.messageID] = message
            }
        }
        let position = Dictionary((options.order ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let format = Formats(options.calendar)

        enum Run { case quote([String]), omitted(Int) }
        var runs: [Run] = []
        var previous: MessageSnapshot?
        var previousReacted = false
        var lastDay: DateComponents?
        for id in ids {
            let message = byID[id]!
            let date = millis(message.messageID).map { Date(timeIntervalSince1970: Double($0) / 1000) }
            let day = date.map { options.calendar.dateComponents([.era, .year, .month, .day], from: $0) }
            let newDay = day != nil && day != lastDay
            let reacted = message.isTombstone ? "" : reactionLine(options.reactions(message))
            var omitted = 0
            if let previous, let before = position[previous.messageID] {
                omitted = (position[message.messageID] ?? 0) - before - 1
            }
            if omitted > 0 { runs.append(.omitted(omitted)) }
            if runs.isEmpty || !isGrouped(previous, message) || newDay || !reacted.isEmpty || previousReacted || omitted > 0 {
                // The first date carries its year whenever it is; later ones only when it isn't `now`'s.
                let dayText = newDay ? date.map { format.day($0, now: lastDay == nil ? nil : options.now) } ?? "" : ""
                let when = [dayText, date.map(format.time.string) ?? ""].filter { !$0.isEmpty }.joined(separator: " at ")
                var header = "**\(inline(options.nameOf(message)))**"
                if !when.isEmpty { header += " · \(when)" }
                if !reacted.isEmpty { header += " (\(reacted))" }
                runs.append(.quote([header]))
            }
            if let day { lastDay = day }
            guard case .quote(var lines) = runs.removeLast() else { preconditionFailure("a header precedes every message") }
            if let replyTo = message.replyTo, !message.isTombstone {
                lines.append(replyLine(replyTo, byID: byID, options: options))
            }
            lines.append(bodyOf(message))
            runs.append(.quote(lines))
            previous = message
            previousReacted = !reacted.isEmpty
        }
        return runs.map { run in
            switch run {
            case .quote(let lines): quoted(lines.joined(separator: "\n\n"))
            case .omitted(let count): "_(\(count == 1 ? "1 message" : "\(count) messages") omitted)_"
            }
        }.joined(separator: "\n\n")
    }

    /// The latest time a JavaScript `Date` holds: apron-web gives a later ID no time, so neither
    /// does the log.
    private static let maxDateMillis: UInt64 = 8_640_000_000_000_000

    /// A log ID's epoch milliseconds (§2), or nil past `maxDateMillis`.
    private static func millis(_ id: LogID) -> UInt64? {
        guard let value = UInt64(id.text), value <= maxDateMillis else { return nil }
        return value
    }

    /// apron-web's `isGrouped`: same sender as the previous message, within five minutes, and
    /// never a reply.
    private static func isGrouped(_ previous: MessageSnapshot?, _ message: MessageSnapshot) -> Bool {
        if message.replyTo != nil, !message.isTombstone { return false }
        guard let previous, !previous.from.userID.isEmpty, previous.from.userID == message.from.userID,
              let before = millis(previous.messageID), let after = millis(message.messageID)
        else { return false }
        return Int64(after) - Int64(before) < 5 * 60 * 1000
    }

    private struct Formats {
        let dayFormat: DateFormatter
        let dayYearFormat: DateFormatter
        let time: DateFormatter
        let calendar: Calendar

        init(_ calendar: Calendar) {
            self.calendar = calendar
            func formatter(_ template: String) -> DateFormatter {
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.locale = calendar.locale ?? .autoupdatingCurrent
                formatter.timeZone = calendar.timeZone
                formatter.setLocalizedDateFormatFromTemplate(template)
                return formatter
            }
            dayFormat = formatter("EEEEMMMd")
            dayYearFormat = formatter("EEEEMMMdy")
            time = formatter("jmm")
        }

        /// `Friday, Oct 30`, with the year when it isn't `now`'s, or always without `now`.
        func day(_ date: Date, now: Date?) -> String {
            let sameYear = now.map { calendar.component(.year, from: $0) == calendar.component(.year, from: date) } ?? false
            return (sameYear ? dayFormat : dayYearFormat).string(from: date)
        }
    }

    /// Reactions as a header lists them, `👍 from Ben, Cy; 👎 from Ada`, or empty for none.
    private static func reactionLine(_ reactions: [Reaction]?) -> String {
        (reactions ?? []).filter { $0.count > 0 }.map { reaction in
            var names = reaction.names.map(inline)
            let unnamed = reaction.count - names.count
            if unnamed > 0 { names.append(names.isEmpty ? "\(unnamed) \(unnamed == 1 ? "person" : "people")" : "\(unnamed) more") }
            return "\(inline(reaction.emoji)) from \(names.joined(separator: ", "))"
        }.joined(separator: "; ")
    }

    /// Text with the characters that would make it Markdown syntax escaped.
    private static func inline(_ text: String) -> String {
        escaped(text, "\\`*_[]<~")
    }

    private static func escaped(_ text: String, _ syntax: String) -> String {
        let syntax = Set(syntax.unicodeScalars)
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if syntax.contains(scalar) { out.append("\\") }
            out.append(scalar)
        }
        return String(out)
    }

    /// Text as a block quote: each line behind `> `, and a bare `>` for a blank one so the quote runs on.
    private static func quoted(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
    }

    /// A message's text as written and its images, or a note when it has neither.
    private static func bodyOf(_ message: MessageSnapshot) -> String {
        if message.isTombstone { return "_(deleted)_" }
        let text = (message.body?["text"]?.stringValue ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let embeds = message.embedList
        let images = embeds.compactMap(imageOf)
        if !text.isEmpty || !images.isEmpty { return ([text] + images).filter { !$0.isEmpty }.joined(separator: "\n\n") }
        return embeds.isEmpty ? "_(empty)_" : "_(attachment)_"
    }

    /// An uploaded image (§4.8.4) as a Markdown image, alt text from its title; nil for any
    /// other embed, or one still uploading.
    private static func imageOf(_ embed: Embed) -> String? {
        guard embed.kind == "upload", embed.og?.video == nil, let url = embed.og?.image?.url,
              ["http", "https"].contains(url.scheme?.lowercased())
        else { return nil }
        let title = [embed.title, embed.og?.title].compactMap { $0 }.first { !$0.isEmpty } ?? "image"
        let alt = escaped(title.replacing(/\s+/, with: " "), "\\[]")
        // A URL is already escaped but for parentheses, which would end the destination early.
        let link = url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        return "![\(alt)](\(link))"
    }

    /// A reply's line, quoted: who it answers and the first line of what they wrote, or a note
    /// when that message isn't here.
    private static func replyLine(_ id: LogID, byID: [LogID: MessageSnapshot], options: Options) -> String {
        guard let target = byID[id] ?? options.lookup(id) else { return "> ↪ _(an earlier message)_" }
        if target.isTombstone { return "> ↪ _(a deleted message)_" }
        return "> ↪ **\(inline(options.nameOf(target)))**: \(inline(replySnippet(target)))"
    }

    /// The first line of a reply's target, ending in `…` wherever it leaves later lines out too.
    private static func replySnippet(_ target: MessageSnapshot) -> String {
        var snippet = MessageText.snippet(target.body)
        if snippet.isEmpty { return MessageText.embedsLabel(target.body) ?? "Empty message" }
        let lines = MessageText.plain(target.body).split(separator: "\n").count { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines > 1, !snippet.hasSuffix("…") { snippet += "…" }
        return snippet
    }
}
