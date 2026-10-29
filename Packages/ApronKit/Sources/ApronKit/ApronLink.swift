import Foundation

/// An Apron link (link.apron.chat SPEC §1, §2; PROTOCOL.md Appendix A.4): a server, or a room,
/// message or user on one, in the web form or the URI form:
///
/// ```text
/// https://link.apron.chat/#server=wss://chat.example/ws&room=general&message=1724803200042
/// apron:?server=wss://chat.example/ws&room=general&message=1724803200042
/// ```
///
/// Each key takes its first value. Keys in a link.apron.chat query count after the fragment's,
/// and a credential there refuses the whole link: its host has already seen it. A credential
/// (`token`, with its `state`) is read only from a web form's fragment, never from an `apron:`
/// URI, which any app can send. A link without `server` is relative (§5): only content from a
/// server may hold one, and it refers to that server (`resolved(against:)`).
public struct ApronLink: Hashable, Sendable {
    public var server: URL?
    public var room: String?
    public var message: LogID?
    public var user: String?
    /// A sign-in token or an invite (§2.1). Never written.
    public var token: String?
    public var state: String?
    /// Keys this reader does not know, in order, which a writer keeps (§2).
    public var otherKeys: [Pair] = []

    public struct Pair: Hashable, Sendable {
        public var key: String
        public var value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public init(server: URL? = nil, room: String? = nil, message: LogID? = nil, user: String? = nil) {
        self.server = server
        self.room = room
        self.message = message
        self.user = user
    }

    public init?(_ url: URL) { self.init(url.absoluteString) }

    /// Nil when the text is not an Apron link, or is one this reader refuses: a key that does
    /// not decode, a bad `room`, `user` or `message`, a `message` without `room`, a `server`
    /// this client cannot reach, a credential without `server` or in a query, or no place at all.
    public init?(_ text: String) {
        guard let lists = Self.keyLists(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let keys = Self.pairs(lists.keys), let query = Self.pairs(lists.query) else { return nil }
        guard !query.contains(where: { $0.key == "token" }) else { return nil }
        let all = keys + query
        func first(_ key: String) -> String? { all.first { $0.key == key }?.value }
        if let value = first("server") {
            guard let server = Self.reachable(value) else { return nil }
            self.server = server
        }
        if let value = first("room") {
            guard OpaqueID.isValid(value) else { return nil }
            room = value
        }
        if let value = first("message") {
            guard let message = LogID(value), room != nil else { return nil }
            self.message = message
        }
        if let value = first("user") {
            guard OpaqueID.isValid(value) else { return nil }
            user = value
        }
        if lists.isWeb, let value = keys.first(where: { $0.key == "token" })?.value {
            guard !value.isEmpty, server != nil else { return nil }
            token = value
            state = first("state")
        }
        guard server != nil || room != nil || user != nil else { return nil }
        otherKeys = all.filter { !Self.known.contains($0.key) }
    }

    /// A relative link made absolute against the server that sent the content holding it (§5).
    public func resolved(against sender: URL) -> ApronLink {
        var link = self
        if link.server == nil { link.server = sender }
        return link
    }

    /// The web form, for copying and sharing (§1), or nil for a relative link. It never carries
    /// a credential: a client never writes a sign-in link (§2.1).
    public var webURL: URL? {
        guard let server else { return nil }
        var pairs = [Pair(key: "server", value: server.absoluteString)]
        if let room { pairs.append(Pair(key: "room", value: room)) }
        if let message { pairs.append(Pair(key: "message", value: message.text)) }
        if let user { pairs.append(Pair(key: "user", value: user)) }
        pairs += otherKeys
        let list = pairs.map { "\(Self.encode($0.key))=\(Self.encode($0.value))" }.joined(separator: "&")
        return URL(string: "https://link.apron.chat/#" + list)
    }

    private static let known: Set<String> = ["server", "room", "message", "user", "token", "state"]

    /// The fragment's (or the URI's) key list, and a link.apron.chat query's.
    private static func keyLists(_ text: String) -> (keys: String, query: String, isWeb: Bool)? {
        if text.lowercased().hasPrefix("apron:?") {
            let rest = text.dropFirst("apron:?".count)
            return (String(rest.prefix { $0 != "#" }), "", false)
        }
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "link.apron.chat", parts.port == nil, parts.user == nil, parts.password == nil,
              ["", "/"].contains(parts.percentEncodedPath) else { return nil }
        return (parts.percentEncodedFragment ?? "", parts.percentEncodedQuery ?? "", true)
    }

    /// `application/x-www-form-urlencoded` pairs, or nil when one does not decode.
    private static func pairs(_ list: String) -> [Pair]? {
        var out: [Pair] = []
        for item in list.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = decode(parts[0]), let value = decode(parts.count > 1 ? parts[1] : "") else { return nil }
            out.append(Pair(key: key, value: value))
        }
        return out
    }

    private static func decode(_ text: Substring) -> String? {
        text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    /// §4: ASCII letters, digits, `-._~:/` as they are, everything else percent-encoded.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/")

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// A `server` this client reaches (§3): `wss` with a host, or `ws` on a loopback host, with
    /// no user name, password or fragment.
    private static func reachable(_ value: String) -> URL? {
        guard let url = URL(string: value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { return nil }
        switch parts.scheme {
        case "wss": return url
        case "ws": return isLoopback(host) ? url : nil
        default: return nil
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare.hasSuffix(".localhost") || bare == "::1" { return true }
        let octets = bare.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}
