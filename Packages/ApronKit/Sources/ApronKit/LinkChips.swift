import Foundation

/// An Apron link written as its own URL, drawn in place of it as a chip that says what it is
/// (Appendix A.4), as apron-web's `resolveLink` (#119): "Message" with " in #general", a room's
/// title, a thread's title with " in #general", or a known user as `@name`. One to another
/// server is its host with " · Message" or " · Room", nothing looked up.
public struct LinkChip: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case message, room, thread
        /// A known user on this server, which reads as a mention of them.
        case user(String)
        /// A message or room on another server: opening it leaves this one.
        case elsewhere
    }

    public var kind: Kind
    public var label: String
    /// The quieter words after the label.
    public var detail: String?

    public init(kind: Kind, label: String, detail: String? = nil) {
        self.kind = kind
        self.label = label
        self.detail = detail
    }

    /// The chip's words, as the timeline shows them.
    public var words: String { label + (detail ?? "") }

    /// What VoiceOver reads in place of the link.
    public var spoken: String {
        guard kind == .elsewhere else { return words }
        let what = detail == LinkChip.messageDetail ? "Message" : "Room"
        return "\(what) on \(label), another server"
    }

    static let messageDetail = " · Message"
}

/// Marks a link chip's label or detail in rendered text (`MessageText`). The run keeps the link
/// as written, which a tap opens through the link routing.
public enum LinkChipKey: AttributedStringKey {
    public typealias Value = LinkChipPart
    public static let name = "ApronLinkChip"
}

/// One part of a link chip in rendered text: its label, or the quieter detail after it.
public struct LinkChipPart: Hashable, Sendable {
    public var chip: LinkChip
    public var isDetail: Bool
}

extension ServerSession {
    /// The chip for an Apron link written as its own URL, from what this session holds, or nil to
    /// leave it a link: one that is not a place (no `room`, a credential, a key this reader does
    /// not know, a `message` with a `user`), a user this session does not know, or a user on
    /// another server. A link without a server is this server's (§5).
    public func linkChip(_ url: URL) -> LinkChip? {
        guard let read = ApronLink(url), let roomID = read.room, read.token == nil, read.otherKeys.isEmpty,
              read.message == nil || read.user == nil else { return nil }
        let link = read.resolved(against: record.url)
        guard let server = link.server, server == record.url else {
            guard link.user == nil, let server = link.server, let host = Self.host(of: server) else { return nil }
            return LinkChip(kind: .elsewhere, label: host, detail: link.message == nil ? " · Room" : LinkChip.messageDetail)
        }
        let room = TextDirection.isolated(referencedTitle(roomID) ?? roomID)
        if let userID = link.user {
            guard let user = users.user(userID).flatMap(UserObject.init) else { return nil }
            return LinkChip(kind: .user(userID), label: "@" + TextDirection.isolated(displayName(for: user)))
        }
        if link.message != nil { return LinkChip(kind: .message, label: "Message", detail: " in #" + room) }
        if let parentID = store.room(roomID)?.parentRoomID {
            return LinkChip(kind: .thread, label: room, detail: " in #" + TextDirection.isolated(referencedTitle(parentID) ?? parentID))
        }
        return LinkChip(kind: .room, label: room)
    }

    /// A server's host as the web's `URL.host` writes it, with its port when it has one.
    private static func host(of server: URL) -> String? {
        guard let parts = URLComponents(url: server, resolvingAgainstBaseURL: false), let host = parts.host, !host.isEmpty else { return nil }
        return parts.port.map { "\(host):\($0)" } ?? host
    }
}
