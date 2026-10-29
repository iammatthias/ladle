import Foundation

/// How much of the message text a server takes is used, in UTF-8 bytes. No server states its
/// limit: Cloudflare's demo takes 4,096 bytes of text (its SPEC §6, `max_text_bytes`), and the
/// Rust server is adopting the same, so Ladle holds every server to it.
public struct TextLimit: Hashable, Sendable {
    public static let maxBytes = 4096
    /// The counter shows from here: the last 512 bytes.
    static let counterFrom = maxBytes - 512

    /// Bytes of the text as it is sent: trimmed, and without the first slash of a `//` message.
    public let used: Int

    public init(_ composed: String) {
        used = ServerSession.Draft(text: composed.trimmingCharacters(in: .whitespacesAndNewlines)).text.utf8.count
    }

    public var remaining: Int { Self.maxBytes - used }
    public var isOver: Bool { used > Self.maxBytes }
    public var showsCounter: Bool { used >= Self.counterFrom }
}
