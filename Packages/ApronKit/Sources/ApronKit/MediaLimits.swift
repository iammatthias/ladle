import Foundation

/// The server's media, from capability `ext:media` (EXTENSIONS.md): origins besides its own that
/// serve its files, and the types and sizes of file it takes as attachments, avatars and custom
/// emoji. Without the capability nothing is known, and the server's 413 or 415 decides.
public struct MediaLimits: Hashable, Sendable {
    public struct Limits: Hashable, Sendable {
        public var maxBytes: Int?
        public var maxSide: Int?

        public init(maxBytes: Int? = nil, maxSide: Int? = nil) {
            self.maxBytes = maxBytes
            self.maxSide = maxSide
        }
    }

    /// MIME patterns (`type/subtype`, `type/*`, `*/*`, lowercased) and their limits.
    public typealias Category = [String: Limits]

    public var origins: [String]
    public var upload: Category?
    public var avatar: Category?
    /// Images for custom emoji (`ext:emoji`); Ladle adds none, so nothing reads it yet.
    public var emoji: Category?

    /// Nil without capability `ext:media`. Fields of the wrong type are ignored one by one.
    public init?(server: ServerInfo?) {
        guard let server, server.has("ext:media") else { return nil }
        let media = server.ext?["media"]
        origins = (media?["origins"]?.arrayValue ?? []).compactMap { Self.origin($0.stringValue) }
        upload = Self.category(media?["upload"])
        avatar = Self.category(media?["avatar"])
        emoji = Self.category(media?["emoji"])
    }

    /// What a category says about a file of `contentType`.
    public enum Verdict: Hashable, Sendable {
        /// The server stated nothing for this category.
        case unknown
        /// No pattern matches the type: the server does not take it.
        case refused
        case allowed(Limits)
    }

    /// The limits of the most specific pattern alone: the exact type, then its group, then
    /// `*/*`. Limits never combine across patterns.
    public static func verdict(for contentType: String, in category: Category?) -> Verdict {
        guard let category else { return .unknown }
        let type = contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let group = type.split(separator: "/").first.map { "\($0)/*" } ?? ""
        for pattern in [type, group, "*/*"] {
            if let limits = category[pattern] { return .allowed(limits) }
        }
        return .refused
    }

    private static func category(_ value: JSONValue?) -> Category? {
        guard let entries = value?.objectValue else { return nil }
        var category: Category = [:]
        for (pattern, limits) in entries {
            guard let object = limits.objectValue else { continue }
            func positive(_ key: String) -> Int? { object[key]?.intValue.flatMap { $0 > 0 ? $0 : nil } }
            let parts = pattern.lowercased().split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            category[pattern.lowercased()] = Limits(maxBytes: positive("max_bytes"), maxSide: positive("max_side"))
        }
        return category
    }

    /// An exact `https:` origin, or `http:` on a loopback host; nothing else.
    private static func origin(_ text: String?) -> String? {
        guard let text, let url = URL(string: text), let origin = MediaPolicy.origin(of: url), origin == text.lowercased() else { return nil }
        let host = url.host()?.lowercased() ?? ""
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        return url.scheme?.lowercased() == "https" || local ? origin : nil
    }
}
