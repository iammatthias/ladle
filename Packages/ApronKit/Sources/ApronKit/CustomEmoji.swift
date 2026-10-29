import Foundation

/// One custom emoji (EXTENSIONS.md, `ext:emoji`): an image the server defines, which users write
/// as its key, `:name:`, in reactions and text.
public struct CustomEmoji: Hashable, Sendable {
    public var key: String
    public var url: URL
    /// Hover and screen reader text.
    public var alt: String?
    /// Width over height, from the catalog's `width` and `height` together; nil is square.
    public var aspectRatio: Double?
    /// A still copy of an animated image.
    public var staticURL: URL?
    /// Groups the picker.
    public var category: String?
    /// More words to search by.
    public var tags: [String]
    /// Rendered, but not offered in the picker.
    public var hidden: Bool

    /// What VoiceOver reads and a long press shows: `alt`, else the key.
    public var label: String { alt ?? key }

    /// The image to show: the still copy where the user prefers reduced motion and there is one.
    public func imageURL(reduceMotion: Bool) -> URL {
        reduceMotion ? staticURL ?? url : url
    }

    /// Whether the string is a key: `:`, one or more of `[A-Za-z0-9_+-]`, and `:`.
    public static func isKey(_ text: some StringProtocol) -> Bool {
        guard text.count >= 3, text.first == ":", text.last == ":" else { return false }
        return text.dropFirst().dropLast().unicodeScalars.allSatisfy(isNameScalar)
    }

    static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A" ... "Z", "a" ... "z", "0" ... "9", "_", "+", "-": true
        default: false
        }
    }
}

/// A server's catalog of custom emoji, by key. Decoded entry by entry: a key that isn't one, or an
/// entry whose `url` may not load as an avatar would (§4.8.6), is left out, and a field of the
/// wrong type is left out on its own.
public struct EmojiCatalog: Hashable, Sendable {
    public private(set) var emoji: [String: CustomEmoji] = [:]

    public init(json: JSONValue, policy: MediaPolicy) {
        for (key, entry) in json.objectValue ?? [:] {
            guard CustomEmoji.isKey(key), entry.objectValue != nil, let url = Self.image(entry["url"], policy) else { continue }
            let width = entry["width"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil }
            let height = entry["height"]?.doubleValue.flatMap { $0 > 0 ? $0 : nil }
            emoji[key] = CustomEmoji(
                key: key, url: url,
                alt: Self.text(entry["alt"]),
                aspectRatio: width.flatMap { width in height.map { width / $0 } },
                staticURL: Self.image(entry["static_url"], policy),
                category: Self.text(entry["category"]),
                tags: (entry["tags"]?.arrayValue ?? []).compactMap(Self.text),
                hidden: entry["hidden"]?.boolValue == true
            )
        }
    }

    public subscript(key: String) -> CustomEmoji? { emoji[key] }

    /// The emoji the picker offers, without `hidden` ones: by category, those without one first,
    /// then by key, in code point order (the catalog's own order does not survive decoding).
    public var offered: [CustomEmoji] {
        emoji.values.filter { !$0.hidden }.sorted {
            let (lhs, rhs) = ($0.category ?? "", $1.category ?? "")
            return lhs == rhs ? codePointLess($0.key, $1.key) : codePointLess(lhs, rhs)
        }
    }

    /// The offered emoji a search finds, those it finds by name first: by the key or its name,
    /// `alt`, or a tag, without regard to case.
    public func search(_ query: String, limit: Int = .max) -> [CustomEmoji] {
        var needle = Substring(query.trimmingCharacters(in: .whitespaces).lowercased())
        if needle.hasPrefix(":") { needle = needle.dropFirst() }
        if needle.hasSuffix(":") { needle = needle.dropLast() }
        guard !needle.isEmpty else { return Array(offered.prefix(limit)) }
        let ranked: [(emoji: CustomEmoji, rank: Int)] = offered.compactMap { emoji in
            let name = emoji.key.dropFirst().dropLast().lowercased()
            let rank: Int? = if name == needle { 0 } else if name.hasPrefix(needle) { 1 } else if name.contains(needle) { 2 }
                else if ([emoji.alt ?? ""] + emoji.tags).contains(where: { $0.lowercased().contains(needle) }) { 3 } else { nil }
            return rank.map { (emoji, $0) }
        }
        return ranked.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.prefix(limit).map(\.element.emoji)
    }

    private static func image(_ value: JSONValue?, _ policy: MediaPolicy) -> URL? {
        guard let text = value?.stringValue, let url = URL(string: text), policy.allowsAvatar(url) else { return nil }
        return url
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return TextDirection.withoutOverrides(text)
    }
}

/// Text split around the keys it holds, scanning from left to right (EXTENSIONS.md, `ext:emoji`):
/// at each `:`, if the text up to the next `:` is a key `known` accepts, it is one and the scan
/// goes on after it; otherwise the scan goes on at that next `:`. So keys can be adjacent
/// (`:a::b:`), and `12:30:partyparrot:` holds `:partyparrot:`.
public enum EmojiKeys {
    /// The ranges of the known keys in the text, in order.
    public static func ranges(in text: String, known: (String) -> Bool) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var at = text.firstIndex(of: ":")
        while let open = at, let close = text[text.index(after: open)...].firstIndex(of: ":") {
            let range = open ..< text.index(after: close)
            let key = String(text[range])
            if CustomEmoji.isKey(key), known(key) {
                found.append(range)
                at = text[range.upperBound...].firstIndex(of: ":")
            } else {
                at = close
            }
        }
        return found
    }

    /// Whether the text holds anything that could be a key, so a catalog not yet fetched is
    /// needed to show it.
    public static func mayHaveKeys(_ text: String) -> Bool {
        !ranges(in: text, known: { _ in true }).isEmpty
    }
}

extension ServerInfo {
    /// `ext.emoji.catalog_url`, while the server lists `ext:emoji`: an `https:` URL, an `http:`
    /// one on a loopback host, or a `data:application/json` URL. Nil for anything else.
    public var emojiCatalogURL: URL? {
        guard has("ext:emoji"), let text = ext?["emoji"]?["catalog_url"]?.stringValue, let url = URL(string: text) else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url.host() == nil ? nil : url
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(url.host()?.lowercased() ?? "") ? url : nil
        case "data":
            let type = text.dropFirst("data:".count).prefix { $0 != ";" && $0 != "," }
            return type.lowercased() == "application/json" ? url : nil
        default: return nil
        }
    }
}

/// Fetches a catalog: no cookies, no credentials and no referrer, so the fetch tells the host
/// nothing the server didn't put in the URL. A catalog over 4 MB is no catalog.
public enum EmojiCatalogFetch {
    public static let maxBytes = 4 << 20

    public static let live: @Sendable (URL) async throws -> Data = { url in
        let data: Data
        if url.scheme?.lowercased() == "data" {
            data = try Data(contentsOf: url)
        } else {
            let (body, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) { throw URLError(.badServerResponse) }
            data = body
        }
        guard data.count <= maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
}
