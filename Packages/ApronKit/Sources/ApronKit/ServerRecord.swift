import Foundation
import Synchronization

/// One server the app knows, with its single account. Persisted as JSON; holds no secrets. The
/// bearer token lives in the `TokenStore`, keyed by `id`.
///
/// Decoding supplies a default for every field added after `id` and `url`, so files saved by an
/// older build keep loading. Keep that promise when adding fields.
public struct ServerRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// The server's WebSocket endpoint, `ws(s)://host/ws`.
    public var url: URL
    public var label: String
    /// The origin the account's bearer token is bound to, sent as the WebSocket `Origin` header
    /// (§3.2.1, §4.10). Defaults to `https://<host>` of `url`; the user may edit it.
    public var origin: String
    /// The relying party ID for native passkeys, when this server is an associated domain.
    public var rpID: String?
    public var account: Account?

    public struct Account: Codable, Hashable, Sendable {
        public var userID: String
        public var name: String?
        /// The `auth` scheme that signed this account in, such as `token` or `email`.
        public var scheme: String

        public init(userID: String, name: String? = nil, scheme: String) {
            self.userID = userID
            self.name = name
            self.scheme = scheme
        }
    }

    public init(id: UUID = UUID(), url: URL, label: String? = nil, origin: String? = nil, rpID: String? = nil, account: Account? = nil) {
        self.id = id
        self.url = url
        self.label = label ?? Self.defaultLabel(for: url)
        self.origin = origin ?? Self.defaultOrigin(for: url)
        self.rpID = rpID
        self.account = account
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        url = try container.decode(URL.self, forKey: .url)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? Self.defaultLabel(for: url)
        origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? Self.defaultOrigin(for: url)
        rpID = try container.decodeIfPresent(String.self, forKey: .rpID)
        account = try container.decodeIfPresent(Account.self, forKey: .account)
    }

    public static func defaultLabel(for url: URL) -> String {
        url.host() ?? url.absoluteString
    }

    /// `https://host`, with the port only when `url` names one.
    public static func defaultOrigin(for url: URL) -> String {
        guard let host = url.host() else { return url.absoluteString }
        return "https://" + host + (url.port.map { ":\($0)" } ?? "")
    }
}

/// `servers.json` in Application Support. Whole-file replace, written atomically.
public struct ServerStore: Sendable {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "servers.json")
    }

    /// `<Application Support>/Apron/servers.json`.
    public static func applicationSupport() throws -> ServerStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return ServerStore(directory: base.appending(path: "Apron", directoryHint: .isDirectory))
    }

    public func load() throws -> [ServerRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path()) else { return [] }
        return try JSONDecoder().decode([ServerRecord].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ records: [ServerRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}

/// Where bearer tokens live, keyed by server. The app's implementation is the Keychain; tests use
/// `InMemoryTokenStore`.
public protocol TokenStore: Sendable {
    func token(for serverID: UUID) throws -> String?
    /// Stores the token, or removes it when nil.
    func setToken(_ token: String?, for serverID: UUID) throws
}

public final class InMemoryTokenStore: TokenStore {
    private let tokens = Mutex<[UUID: String]>([:])

    public init() {}

    public func token(for serverID: UUID) throws -> String? {
        tokens.withLock { $0[serverID] }
    }

    public func setToken(_ token: String?, for serverID: UUID) throws {
        tokens.withLock { $0[serverID] = token }
    }
}
