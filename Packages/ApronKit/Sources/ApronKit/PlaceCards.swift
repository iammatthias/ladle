import Foundation

/// A card for an Apron link to a message, room or thread, drawn from what this device already
/// holds, as apron-web's LinkCard: a loaded message as its sender, its room and its first lines,
/// and a room or thread (or a message not loaded here) as its title, a lock when private, and
/// its member count when known.
public struct PlaceCard: Hashable, Sendable, Identifiable {
    public enum Content: Hashable, Sendable {
        case message(sender: String, preview: String)
        case room
    }

    /// The place, absolute and with no other keys: what a tap opens.
    public let link: ApronLink
    public let content: Content
    public let roomTitle: String
    public let isPrivate: Bool
    public let isThread: Bool
    public let memberCount: Int?

    public var id: ApronLink { link }

    public init(link: ApronLink, content: Content, roomTitle: String, isPrivate: Bool = false, isThread: Bool = false, memberCount: Int? = nil) {
        self.link = link
        self.content = content
        self.roomTitle = roomTitle
        self.isPrivate = isPrivate
        self.isThread = isThread
        self.memberCount = memberCount
    }

    /// At most this many cards on one message, as apron-web's `LINK_CARDS_MAX`.
    public static let limit = 3

    /// Whether `embed` previews a place one of `cards` shows, as apron-web's `previewedByCard`
    /// (#155): its `url` read as an Apron link, made absolute against the sender's server, names
    /// the same server, room and message. Another client may send its own preview of a link this
    /// one draws as a card; one of the two is enough. A user link, or a place with no card, keeps
    /// its embed.
    public static func previews(_ embed: Embed, in cards: [PlaceCard], from sender: URL) -> Bool {
        guard !cards.isEmpty, let written = embed.json["url"]?.stringValue,
              let link = ApronLink(written), link.user == nil, link.token == nil, link.room != nil else { return false }
        let place = link.resolved(against: sender).place
        return cards.contains { $0.link == place }
    }
}

extension ApronLink {
    /// The server, room and message alone, so the same place written two ways compares equal.
    var place: ApronLink { ApronLink(server: server, room: room, message: message) }
}

extension ServerSession {
    /// The cards for the Apron links in a message's text, in order, one per place, at most
    /// `PlaceCard.limit`. A link without a server is this server's (§5). A link to another server
    /// draws from that server's session, which `sessions` gives only while it is signed in. A link
    /// to the message itself, to a user, or to a place the session can't see draws none.
    /// Nothing is fetched to draw a card.
    public func placeCards(in message: MessageSnapshot, sessions: (URL) -> ServerSession? = { _ in nil }) -> [PlaceCard] {
        var cards: [PlaceCard] = []
        for url in MessageText.links(message.body) {
            guard cards.count < PlaceCard.limit, let read = ApronLink(url), read.token == nil, read.user == nil, read.room != nil else { continue }
            let link = read.resolved(against: record.url).place
            if link.server == record.url, link.message == message.messageID { continue }
            let session = link.server == record.url ? self : link.server.flatMap(sessions)
            guard let card = session?.placeCard(link), !cards.contains(where: { $0.link == card.link }) else { continue }
            cards.append(card)
        }
        return cards
    }

    /// The card for a place on this server, or nil when this user can't see it: a room this
    /// session holds no record of, or a private one they are not in. A message shows as itself
    /// when it is loaded and still in the room the link names, else as its room.
    public func placeCard(_ link: ApronLink) -> PlaceCard? {
        guard let roomID = link.room, let room = store.room(roomID),
              room.isPrivate != true || joinedRoomIDs.contains(roomID) else { return nil }
        var content = PlaceCard.Content.room
        if let id = link.message, let target = store.message(id), !target.isTombstone, target.roomID == roomID {
            content = .message(sender: displayName(for: target.from), preview: MessageText.snippet(target.body, lines: 3, max: 280))
        }
        return PlaceCard(link: link, content: content, roomTitle: title(of: roomID), isPrivate: room.isPrivate == true,
                        isThread: room.parentRoomID != nil, memberCount: store.members(of: roomID)?.count)
    }
}

extension SessionStore {
    /// The signed-in session of the saved server at `url`, for a link card from another server.
    public func liveSession(for url: URL) -> ServerSession? {
        guard let record = records.first(where: { $0.url == url }), let session = sessions[record.id],
              session.status == .signedIn else { return nil }
        return session
    }
}
