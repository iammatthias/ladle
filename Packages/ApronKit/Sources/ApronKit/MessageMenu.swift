import Foundation

/// A link in a message's or notice's menu: Open opens `url`, Copy Link and Share give `shared`,
/// its web form (`ApronLink.outbound`), under the link's host.
public struct MenuLink: Hashable, Sendable {
    public var url: URL
    public var shared: URL
    public var title: String
}

/// What a message's menu offers, as the session allows it: reactions, Reply, Copy Text, Select
/// Text, Copy Link, Move To, the body's first three links, and Edit and Delete.
public struct MessageMenu: Sendable {
    /// The quick reactions and More Reactions: signed in, on a server with `reactions`.
    public var reacts: Bool
    /// Reply and the reactions are off, with the reason, for a user who may not write.
    public var mayWrite: Bool
    /// Copy Text's text, as stored.
    public var text: String
    /// Select Text's text, as read (`MessageText.plain`); nil for a message without text.
    public var selectableText: String?
    /// Copy Link's web link to the message.
    public var link: URL?
    /// Move To's rooms, by id: none unless the user may move the message.
    public var moveDestinations: [String]
    public var links: [MenuLink]
    /// Edit and Delete: the user's own message, signed in, may write, on a server with `edit`.
    public var editable: Bool

    @MainActor
    public init(_ message: MessageSnapshot, in session: ServerSession) {
        reacts = session.status == .signedIn && session.server?.has("reactions") == true
        mayWrite = session.mayWrite
        text = message.plainText
        selectableText = message.plainText.isEmpty ? nil : MessageText.plain(message.body)
        link = ApronLink(server: session.record.url, room: message.roomID, message: message.messageID).webURL
        moveDestinations = session.mayMove(message) ? session.moveDestinations(for: message) : []
        links = MenuLink.links(in: message.body, from: session.record.url)
        editable = session.status == .signedIn && session.mayWrite && session.isYou(message.from.userID) && session.server?.has("edit") == true
    }
}

/// What a notice's menu offers: a message's without reactions, replies or edits, and each of
/// its first three code spans to copy on its own (a token, a command), as apron-web's copy
/// buttons on a notice's code. `title` is the line over the notice.
public struct NoticeMenu: Sendable {
    public var title: String?
    /// Copy Text's and Select Text's text, as read.
    public var text: String
    public var code: [String]
    public var links: [MenuLink]

    @MainActor
    public init(_ notice: Notice, in session: ServerSession) {
        switch notice.from.userID {
        case "~private": title = "Only you can see this"
        case "~room": title = nil
        case "~server": title = session.serverName
        default: title = session.displayName(for: notice.from)
        }
        text = MessageText.plain(notice.body)
        code = Array(MessageText.code(notice.body).prefix(3))
        links = MenuLink.links(in: notice.body, from: session.record.url)
    }
}

extension MenuLink {
    /// The first three links in a body.
    static func links(in body: JSONValue?, from server: URL) -> [MenuLink] {
        MessageText.links(body).prefix(3).map { url in
            MenuLink(url: url, shared: ApronLink.outbound(url, from: server), title: url.host() ?? url.absoluteString)
        }
    }
}
