import Foundation

/// Where the viewer lets media load from, as apron-web's Preferences > Media: `trusted` (the
/// chat server's own origin, those it names with `ext:media`, and the viewer's trusted sites) or
/// `any` site. Loading media tells the site that hosts it that someone is reading (§5.5).
public enum MediaPolicy: String, CaseIterable, Hashable, Sendable {
    case trusted
    case any

    /// What a saved value reads as, including those of apron-web's earlier versions: `all` is
    /// `any`, anything else `trusted`.
    init(saved: String?) {
        self = saved == "any" || saved == "all" ? .any : .trusted
    }
}

/// What a media URL does: load, wait for a tap (`MediaAsk`), or not show at all.
public enum MediaDecision: Hashable, Sendable {
    case load(URL)
    case ask(MediaAsk)
    case hidden

    public var url: URL? {
        if case .load(let url) = self { url } else { nil }
    }
}

/// Media that waits for a tap: where it is, its host, and its origin when Always Load can trust
/// it and Block can block it (`https:` with a dotted host, as `MediaSettings.parseOrigins` keeps).
public struct MediaAsk: Hashable, Sendable {
    public var url: URL
    public var host: String
    public var origin: String?
    /// Asked on an export's gate held to its own sites (`MediaSettings.gate(heldToServer:)`).
    public var held = false

    public init(url: URL, host: String, origin: String?) {
        self.url = url
        self.host = host
        self.origin = origin
    }

    init(_ url: URL) {
        self.url = url
        let name = url.host(percentEncoded: false) ?? url.absoluteString
        host = url.port.map { "\(name):\($0)" } ?? name
        origin = MediaSettings.parseOrigins(url.absoluteString).first
    }
}

/// The one place a media URL is decided for one server (§4.8.1, §4.8.6), as apron-web's
/// `mediaGate`: every image, video, audio, avatar, custom emoji and emoji catalog the app loads
/// asks `decide` first. It knows the chat server's HTTP origin, the origins `ext:media` names
/// (EXT.md §6), the viewer's policy, trusted and blocked sites, and the URLs tapped to load this
/// launch. A blocked host wins over everything else: nothing from it loads or asks. Small inline
/// images (`data:`) load from nowhere, so they always show. Links a tap opens are not limited by it.
public struct MediaGate: Hashable, Sendable {
    /// What the media is for. Timeline media from elsewhere waits for a tap; an avatar, a custom
    /// emoji or a catalog never asks, and from anywhere but the server itself loads only over
    /// `https:` (§4.8.6).
    public enum Use: Hashable, Sendable {
        case timeline
        case avatar
    }

    /// The server's HTTP origin, from its WebSocket URL (`wss://h/ws` gives `https://h`).
    public var origin: String?
    /// The origins the server names for its media (`ext:media`).
    public var serverOrigins: Set<String>
    public var policy: MediaPolicy
    /// The viewer's trusted sites, on every server.
    public var viewerOrigins: Set<String>
    /// URLs tapped to load (Load), which load wherever they are.
    public var loadedOnce: Set<URL>
    /// The hosts of the viewer's blocked sites (`blockableHost`), matched whatever the scheme or
    /// port, and every host under them (blocking `tracker.example` blocks `a.tracker.example`).
    public var blockedHosts: Set<String>
    /// Held to the server's own sites, as an export's is until Always Load there.
    public var held: Bool

    public init(serverURL: URL, server: ServerInfo?, policy: MediaPolicy = .trusted, viewerOrigins: some Sequence<String> = [String](),
                loadedOnce: Set<URL> = [], blocked: some Sequence<String> = [String](), held: Bool = false) {
        self.held = held
        origin = Self.httpOrigin(of: serverURL)
        serverOrigins = Set(MediaLimits(server: server)?.origins ?? [])
        self.policy = policy
        self.viewerOrigins = Set(viewerOrigins)
        self.loadedOnce = loadedOnce
        blockedHosts = Set(blocked.compactMap { URL(string: $0).flatMap(Self.blockableHost) })
    }

    public func decide(_ url: URL, for use: Use = .timeline) -> MediaDecision {
        if Self.isSmallDataImage(url) { return .load(url) }
        guard let candidate = Self.origin(of: url) else { return .hidden }
        if let host = Self.blockableHost(of: url), isBlocked(host) { return .hidden }
        if candidate == origin || serverOrigins.contains(candidate) { return .load(url) }
        if policy == .trusted, viewerOrigins.contains(candidate) { return .load(url) }
        switch use {
        case .avatar:
            return policy == .any && url.scheme?.lowercased() == "https" ? .load(url) : .hidden
        case .timeline:
            var ask = MediaAsk(url)
            ask.held = held
            return policy == .any || loadedOnce.contains(url) ? .load(url) : .ask(ask)
        }
    }

    /// `host` or a host it is under is blocked; not one it merely ends like (`eviltracker.example`).
    private func isBlocked(_ host: String) -> Bool {
        guard !blockedHosts.isEmpty else { return false }
        var rest = Substring(host)
        while true {
            if blockedHosts.contains(String(rest)) { return true }
            guard let dot = rest.firstIndex(of: ".") else { return false }
            rest = rest[rest.index(after: dot)...]
        }
    }

    public func allows(_ url: URL, for use: Use = .timeline) -> Bool {
        decide(url, for: use).url != nil
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

    /// The host a blocked one is compared with: lowercased, without a trailing dot, whatever the
    /// scheme or port.
    static func blockableHost(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    static func isSmallDataImage(_ url: URL) -> Bool {
        let text = url.absoluteString
        return text.count <= 65_536 && dataImageURL(.string(text)) != nil
    }
}
