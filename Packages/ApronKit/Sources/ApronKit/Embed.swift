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
    /// A finished stream's kept text (§4.8.5), or any kind's plain `text`.
    public var text: String?
    public var json: JSONValue

    public init?(_ value: JSONValue) {
        guard case .object = value, let kind = value["kind"]?.stringValue else { return nil }
        self.kind = kind
        embedID = value["embed_id"]?.stringValue
        title = value["title"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        url = webURL(value["url"])
        og = OpenGraph(value["og"])
        text = value["text"]?.stringValue
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
    /// The player for a link card: the video, else the audio, when `policy` lets the client load
    /// it. Only `http(s)` media plays, so an inline `data:` image never stands in for a sound.
    /// Nil keeps the image card.
    public func player(policy: MediaPolicy) -> LinkPlayer? {
        func playable(_ media: Media?) -> Media? {
            guard let media, ["http", "https"].contains(media.url.scheme?.lowercased()), policy.allowsMedia(media.url) else { return nil }
            return media
        }
        let picture = image.flatMap { policy.allowsMedia($0.url) ? $0 : nil }
        if let video = playable(video) { return .video(video, poster: picture) }
        if let audio = playable(audio) { return .audio(audio, cover: picture) }
        return nil
    }
}

extension MessageSnapshot {
    /// The body's embeds in display order; entries without a string `kind` are skipped.
    public var embedList: [Embed] { body?["embeds"]?.arrayValue?.compactMap(Embed.init) ?? [] }
}

/// Which URLs a client may load as media for one server (§4.8.1, §4.8.5, §4.8.6): the chat
/// server's own HTTP origin, the origins `ext:media` names (EXT.md §6), and small inline images.
/// Links a click opens are not limited by it.
public struct MediaPolicy: Hashable, Sendable {
    /// The server's HTTP origin, from its WebSocket URL (`wss://h/ws` gives `https://h`).
    public var origin: String?
    public var trustedOrigins: Set<String>

    public init(serverURL: URL, server: ServerInfo?) {
        origin = Self.httpOrigin(of: serverURL)
        trustedOrigins = Set(MediaLimits(server: server)?.origins ?? [])
    }

    /// `og` media and hosted files: the server's origin, or one it names for its media.
    public func allowsMedia(_ url: URL) -> Bool {
        if Self.isSmallDataImage(url) { return true }
        guard let candidate = Self.origin(of: url) else { return false }
        return candidate == origin || trustedOrigins.contains(candidate)
    }

    /// Avatars (§4.8.6): what `allowsMedia` allows, and any `https:` image.
    public func allowsAvatar(_ url: URL) -> Bool {
        allowsMedia(url) || url.scheme?.lowercased() == "https"
    }

    static func httpOrigin(of serverURL: URL) -> String? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "wss", "https": components.scheme = "https"
        case "ws", "http": components.scheme = "http"
        default: return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url.flatMap(origin(of:))
    }

    /// `scheme://host[:port]`, lowercased, without a default port.
    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host()?.lowercased(), !host.isEmpty
        else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let shownHost = host.contains(":") ? "[\(host)]" : host
        guard let port = url.port, port != defaultPort else { return "\(scheme)://\(shownHost)" }
        return "\(scheme)://\(shownHost):\(port)"
    }

    static func isSmallDataImage(_ url: URL) -> Bool {
        let text = url.absoluteString
        return text.count <= 65_536 && dataImageURL(.string(text)) != nil
    }
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
