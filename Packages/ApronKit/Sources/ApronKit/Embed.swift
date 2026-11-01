import Foundation

/// An embed (§4.8), parsed once at the boundary. `json` keeps the wire object, so a save can send
/// it back unchanged (§4.8.2) and an unknown kind can still render its fallback card (§3.5.2).
public struct Embed: Hashable, Sendable {
    public var kind: String
    public var embedID: String?
    public var title: String?
    /// Where a click goes; `http` or `https` only.
    public var url: URL?
    public var og: OpenGraph?
    /// A v9 finished stream's kept text, or any kind's plain `text`.
    public var text: String?
    /// A finished `terminal` embed's kept output (v10 §4.8.6), escapes and all.
    public var output: String?
    public var json: JSONValue

    public init?(_ value: JSONValue) {
        guard case .object = value, let kind = value["kind"]?.stringValue else { return nil }
        self.kind = kind
        embedID = value["embed_id"]?.stringValue
        title = value["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        url = webURL(value["url"])
        og = OpenGraph(value["og"])
        text = value["text"]?.stringValue
        output = value["output"]?.stringValue
        json = value
    }

    /// What an `upload` embed holds (§4.8.4), or nil for another kind.
    public var upload: Upload? {
        guard kind == "upload" else { return nil }
        guard let url else { return .pending }
        if let image = og?.image { return .image(image) }
        if let video = og?.video { return .video(video) }
        if let audio = og?.audio { return .audio(audio) }
        return .file(url)
    }

    /// The name to show: the sender's `title`, else the server's `og.title`.
    public var name: String? { title ?? og?.title }

    /// A v10 `append` embed: live text growing at the end of `body.text` (§4.8.5). Its
    /// finished snapshot has the text in the body and no embed, so the row draws none for it.
    public var isAppend: Bool { kind == "append" }

    /// A finished terminal's output as plain lines (`TerminalText.plain`), or nil while live.
    public var terminalOutput: String? {
        guard kind == "terminal", let output else { return nil }
        return TerminalText.plain(output)
    }
}

/// Terminal output as text, until Ladle renders a terminal: escape sequences dropped, and each
/// carriage return starting its line over, as a terminal would draw it.
public enum TerminalText {
    /// The last `maxLines` lines, without trailing blank ones.
    public static func plain(_ output: String, maxLines: Int = 13) -> String {
        var lines: [String] = []
        var line: [Character] = []
        var column = 0
        var scalars = output.unicodeScalars.makeIterator()
        func put(_ c: Character) {
            if column < line.count { line[column] = c } else { line.append(c) }
            column += 1
        }
        while let scalar = scalars.next() {
            switch scalar {
            case "\u{1B}":
                skipEscape(&scalars)
            case "\n":
                lines.append(String(line)); line = []; column = 0
            case "\r":
                column = 0
            case "\u{08}":
                column = max(0, column - 1)
            case "\t":
                repeat { put(" ") } while column % 8 != 0
            default:
                if scalar.value >= 0x20, scalar.value != 0x7F { put(Character(scalar)) }
            }
        }
        lines.append(String(line))
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    /// Skips one sequence after ESC: CSI up to its final byte, OSC, DCS, SOS, PM and APC up to
    /// BEL or ST, and any other as ESC plus its intermediates and final byte.
    private static func skipEscape(_ scalars: inout String.UnicodeScalarView.Iterator) {
        guard let next = scalars.next() else { return }
        switch next {
        case "[":
            while let s = scalars.next(), !(0x40...0x7E).contains(s.value) {}
        case "]", "P", "X", "^", "_":
            var previous: Unicode.Scalar?
            while let s = scalars.next() {
                if s == "\u{07}" || (previous == "\u{1B}" && s == "\\") { break }
                previous = s
            }
        default:
            var s: Unicode.Scalar? = next
            while let c = s, (0x20...0x2F).contains(c.value) { s = scalars.next() }
        }
    }
}

/// An upload while `url` is absent, then by the media the server described in `og` (§4.8.4).
public enum Upload: Hashable, Sendable {
    case pending
    case image(OpenGraph.Media)
    case video(OpenGraph.Media)
    case audio(OpenGraph.Media)
    /// No `og` media: a file card linking to the file.
    case file(URL)
}

/// The `og` properties clients use (§4.8.1). Others are ignored.
public struct OpenGraph: Hashable, Sendable {
    public struct Media: Hashable, Sendable {
        public var url: URL
        public var type: String?
        public var width: Int?
        public var height: Int?
        public var alt: String?

        init?(_ value: JSONValue?) {
            guard let value, let url = webURL(value["url"]) ?? dataImageURL(value["url"]) else { return nil }
            self.url = url
            type = value["type"]?.stringValue
            width = value["width"]?.intValue.flatMap { $0 > 0 ? $0 : nil }
            height = value["height"]?.intValue.flatMap { $0 > 0 ? $0 : nil }
            alt = value["alt"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }

        /// Width over height, when the server stated both.
        public var aspectRatio: Double? {
            guard let width, let height else { return nil }
            return Double(width) / Double(height)
        }
    }

    public var title: String?
    public var description: String?
    public var siteName: String?
    public var image: Media?
    public var video: Media?
    public var audio: Media?

    /// An `og` a sender writes: text only, since the server drops the media a sender names.
    public init(siteName: String? = nil, title: String? = nil, description: String? = nil) {
        self.siteName = siteName
        self.title = title
        self.description = description
    }

    /// The text fields as the wire's `og` object.
    public var json: JSONValue {
        var object: [String: JSONValue] = [:]
        object["site_name"] = siteName.map(JSONValue.string)
        object["title"] = title.map(JSONValue.string)
        object["description"] = description.map(JSONValue.string)
        return .object(object)
    }

    init?(_ value: JSONValue?) {
        guard let value, case .object = value else { return nil }
        title = value["title"]?.stringValue
        description = value["description"]?.stringValue
        siteName = value["site_name"]?.stringValue
        image = Media(value["image"])
        video = Media(value["video"])
        audio = Media(value["audio"])
    }
}

/// What a link card plays inline from its `og` (§4.8.1: `og.video` and `og.audio` are what a
/// player loads, `og.image` is the preview to show).
public enum LinkPlayer: Hashable, Sendable {
    /// A video, with `og.image` as its poster when the policy allows it.
    case video(OpenGraph.Media, poster: OpenGraph.Media?)
    /// A sound, with `og.image` above its player when the policy allows it.
    case audio(OpenGraph.Media, cover: OpenGraph.Media?)
}

extension OpenGraph {
    /// The player for a link card: the video, else the audio, when `gate` loads it. Only
    /// `http(s)` media plays, so an inline `data:` image never stands in for a sound. Nil keeps
    /// the image card.
    public func player(gate: MediaGate) -> LinkPlayer? {
        func playable(_ media: Media?) -> Media? {
            guard let media, ["http", "https"].contains(media.url.scheme?.lowercased()), gate.allows(media.url) else { return nil }
            return media
        }
        let picture = image.flatMap { gate.allows($0.url) ? $0 : nil }
        if let video = playable(video) { return .video(video, poster: picture) }
        if let audio = playable(audio) { return .audio(audio, cover: picture) }
        return nil
    }

    /// What waits for a tap under a card that has no player, as apron-web's EmbedCard: the
    /// video, else the audio, else the image when it does not show. A video that waits says so
    /// even when its image shows.
    public func ask(gate: MediaGate) -> CardAsk? {
        guard player(gate: gate) == nil else { return nil }
        for (kind, media) in [(CardAsk.Kind.video, video), (.audio, audio), (.image, image)] {
            if let media, case .ask(let ask) = gate.decide(media.url) { return CardAsk(kind: kind, media: media, ask: ask) }
        }
        return nil
    }
}

/// A link card's media that waits for a tap (`OpenGraph.ask(gate:)`).
public struct CardAsk: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case video, audio, image }
    public var kind: Kind
    public var media: OpenGraph.Media
    public var ask: MediaAsk

    /// What the tile names: the kind, an image by its `alt`.
    public var what: String {
        switch kind {
        case .video: "Video"
        case .audio: "Audio"
        case .image: media.alt ?? "Image"
        }
    }
}

extension MessageSnapshot {
    /// The body's embeds in display order; entries without a string `kind` are skipped.
    public var embedList: [Embed] { body?["embeds"]?.arrayValue?.compactMap(Embed.init) ?? [] }
}

/// An `http` or `https` URL from a JSON string.
func webURL(_ value: JSONValue?) -> URL? {
    guard let text = value?.stringValue, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https", url.host() != nil else { return nil }
    return url
}

/// `data:image/{png,jpeg,gif,webp};base64,…` (§4.8.6).
func dataImageURL(_ value: JSONValue?) -> URL? {
    guard let text = value?.stringValue else { return nil }
    let prefixes = ["png", "jpeg", "gif", "webp"].map { "data:image/\($0);base64," }
    guard let prefix = prefixes.first(where: { text.hasPrefix($0) }) else { return nil }
    let payload = text.dropFirst(prefix.count)
    let base64 = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    guard !payload.isEmpty, payload.unicodeScalars.allSatisfy(base64.contains) else { return nil }
    return URL(string: text)
}
