/// The `server` frame (§3.1). Each one fully replaces the previous.
public struct ServerInfo: Hashable, Sendable {
    public var apron: Int
    /// Sign-in schemes in the server's preference order.
    public var auth: [String]
    public var agent: String?
    public var capabilities: [String]
    public var welcome: String?
    /// The server's plain display name; without it, clients show its address.
    public var title: String?
    /// CommonMark: what the server is about.
    public var description: String?
    /// The server's icon, under the rules for user avatars (§4.8.6).
    public var avatar: String?
    /// Schemes that create accounts; nil means the same as `auth`.
    public var signup: [String]?
    /// Seconds between client pings; nil when the server wants none.
    public var ping: Double?
    public var status: [String]?
    public var push: JSONValue?
    public var ext: JSONValue?

    /// Requires `apron` and `auth`; every other field is optional.
    public init?(params: JSONValue?) {
        guard let params, let apron = params["apron"]?.intValue, let auth = Self.strings(params["auth"]) else { return nil }
        self.apron = apron
        self.auth = auth
        agent = params["agent"]?.stringValue
        capabilities = Self.strings(params["capabilities"]) ?? []
        welcome = params["welcome"]?.stringValue
        title = params["title"]?.stringValue
        description = params["description"]?.stringValue
        avatar = params["avatar"]?.stringValue
        signup = Self.strings(params["signup"])
        ping = params["ping"]?.doubleValue
        status = Self.strings(params["status"])
        push = params["push"]
        ext = params["ext"]
    }

    public func has(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    /// Whether the server keeps read cursors: `ext.settings.read_cursors` under capability
    /// `ext:settings` (EXTENSIONS.md), true unless it says `false`.
    public var keepsReadCursors: Bool {
        !(has("ext:settings") && ext?["settings"]?["read_cursors"]?.boolValue == false)
    }

    private static func strings(_ value: JSONValue?) -> [String]? {
        guard let elements = value?.arrayValue else { return nil }
        return elements.compactMap(\.stringValue)
    }
}
