import Foundation

/// What an edit changes besides the text, as apron-web's MessageEditor (#70): embeds left out,
/// uploads renamed, and the reply reference removed. Nothing goes until Save, which sends the
/// message's embeds as stored minus those removed (§4.4: a save replaces the client fields); a
/// server that hosts an upload keeps its `embed_id`, `url` and `og` as its own.
public struct MessageEdit: Hashable, Sendable {
    public let message: MessageSnapshot
    /// Embeds removed, by their place in the message's `body.embeds`.
    public private(set) var removed: Set<Int> = []
    /// New names by place, only those that differ from the tile's.
    public private(set) var titles: [Int: String] = [:]
    public var removesReply = false

    public init(_ message: MessageSnapshot) {
        self.message = message
    }

    private var stored: [JSONValue] { message.body?["embeds"]?.arrayValue ?? [] }

    /// The embeds the editor shows, in order, each with its name as it will be saved.
    public var tiles: [EmbedTile] {
        stored.enumerated().compactMap { index, value in
            guard !removed.contains(index), let embed = Embed(value) else { return nil }
            return EmbedTile(id: index, embed: embed, name: titles[index] ?? EmbedTile.name(of: embed))
        }
    }

    /// The reply the save keeps.
    public var replyTo: LogID? { removesReply ? nil : message.replyTo }

    /// Whether the message keeps an embed, so it may be saved without text (§3.5).
    public var keepsEmbeds: Bool { stored.indices.contains { !removed.contains($0) } }

    public mutating func remove(_ tile: EmbedTile) {
        removed.insert(tile.id)
    }

    /// Renames an upload, as apron-web's AttachmentTile: an empty name changes nothing.
    public mutating func rename(_ tile: EmbedTile, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tile.renamable, !name.isEmpty else { return }
        titles[tile.id] = name == EmbedTile.name(of: tile.embed) ? nil : name
    }

    /// The message as the save sends it: `text`, `body.mentions` (none when empty), the embeds
    /// kept and renamed, and the reply unless removed.
    public func saved(text: String, mentions: [String]) -> MessageSnapshot {
        var body = message.body?.objectValue ?? [:]
        body["text"] = .string(text)
        body["mentions"] = mentions.isEmpty ? nil : .array(mentions.map(JSONValue.string))
        if body["embeds"]?.arrayValue != nil {
            let kept = stored.enumerated().compactMap { index, value -> JSONValue? in
                guard !removed.contains(index) else { return nil }
                return titles[index].map { Self.renamed(value, to: $0) } ?? value
            }
            body["embeds"] = kept.isEmpty ? nil : .array(kept)
        }
        var snapshot = message
        snapshot.body = .object(body)
        snapshot.replyTo = replyTo
        return snapshot
    }

    /// The embed with a new `title`, as apron-web's `renamedEmbed`: its `og.title`, when it
    /// showed the old name, follows for a server that keeps embeds as given.
    static func renamed(_ value: JSONValue, to title: String) -> JSONValue {
        guard var embed = value.objectValue else { return value }
        let old = embed["title"]?.stringValue ?? embed["og"]?["title"]?.stringValue
        embed["title"] = .string(title)
        if var og = embed["og"]?.objectValue, let ogTitle = og["title"]?.stringValue, ogTitle == old {
            og["title"] = .string(title)
            embed["og"] = .object(og)
        }
        return .object(embed)
    }
}

/// One embed of a message being edited, as apron-web's `embedTile`: its name, and whether that
/// name is the sender's to change (an upload's `title`, §4.8.4).
public struct EmbedTile: Identifiable, Hashable, Sendable {
    /// Its place in the message's `body.embeds`.
    public let id: Int
    public let embed: Embed
    public let name: String

    public var renamable: Bool { embed.kind == "upload" }

    /// The line under the name, as apron-web's `embedTile`: what the upload is, or the link's host.
    public var detail: String {
        switch embed.kind {
        case "terminal": return embed.json["output"]?.stringValue != nil ? "Terminal output" : "Live terminal"
        case "append": return "Still arriving"
        case "upload": break
        default: return embed.url?.host() ?? (embed.kind == "iframe" ? "Embedded page" : embed.kind == "html" ? "Embedded content" : "Link")
        }
        switch embed.upload {
        case .pending, nil: return "Uploading…"
        case .image(let media): return media.width.flatMap { w in media.height.map { "\(w) × \($0)" } } ?? "Image"
        case .video: return "Video"
        case .audio: return "Audio"
        case .file:
            let ext = (name as NSString).pathExtension
            return (1 ... 5).contains(ext.count) && ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) ? "\(ext.uppercased()) file" : "File"
        }
    }

    /// What to ask before removing it, as apron-web's `removeEmbedQuestion`, where something
    /// goes with it: an upload's file, a terminal's output, live text. Nil for anything else.
    public var removeQuestion: String? {
        switch embed.kind {
        case "upload": "Remove this attachment? Its file will be deleted."
        case "terminal": embed.json["output"]?.stringValue != nil
            ? "Remove this terminal? Its output will be deleted."
            : "Stop this live terminal? Its output so far will be deleted."
        case "append": "Stop this live text? The text that has arrived so far will be dropped."
        default: nil
        }
    }

    static func name(of embed: Embed) -> String {
        switch embed.kind {
        case "upload": embed.title ?? embed.og?.title.flatMap { $0.isEmpty ? nil : $0 } ?? "File"
        case "terminal": embed.title ?? "Terminal"
        case "append": "Live text"
        default: [embed.og?.title, embed.title, embed.url?.host()].compactMap { $0 }.first { !$0.isEmpty } ?? embed.kind
        }
    }
}

extension ServerSession {
    /// Whether an edit may leave the embed out: not an upload this device is still writing, as
    /// apron-web's `writing`.
    public func mayRemove(_ tile: EmbedTile) -> Bool {
        tile.embed.embedID.map { uploadProgress[$0] == nil } ?? true
    }
}
