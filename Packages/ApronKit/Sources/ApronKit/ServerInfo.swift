/// The `server` frame (§3.1). Each one fully replaces the previous.
public struct ServerInfo: Hashable, Sendable {
    public var apron: Int
    /// Sign-in schemes in the server's preference order.
    public var auth: [String]
    public var agent: String?
    public var capabilities: [String]
    public var welcome: String?
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
        signup = Self.strings(params["signup"])
        ping = params["ping"]?.doubleValue
        status = Self.strings(params["status"])
        push = params["push"]
        ext = params["ext"]
    }

    public func has(_ capability: String) -> Bool {
        capabilities.contains(capability)
    }

    private static func strings(_ value: JSONValue?) -> [String]? {
        guard let elements = value?.arrayValue else { return nil }
        return elements.compactMap(\.stringValue)
    }
}
