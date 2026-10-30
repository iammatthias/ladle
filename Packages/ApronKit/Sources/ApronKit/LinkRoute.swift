import Foundation

/// Where an Apron link that reaches the app, or a tapped reminder, goes (link.apron.chat SPEC):
/// a saved server's sign-in sheet with the link's token filled in (a link never signs in by
/// itself, §6), a place on a saved server, or the Connect sheet to add the link's server, which
/// opens the place once signed in.
public enum LinkRoute: Hashable, Sendable {
    case signIn(ServerRecord, TokenPayload)
    case place(UUID, ApronLink)
    case addServer(TokenPayload, place: ApronLink)

    /// Nil for a link without a server: a relative link has no server that sent it here.
    public init?(_ link: ApronLink, records: [ServerRecord]) {
        guard let server = link.server else { return nil }
        if let record = records.first(where: { $0.url == server }) {
            if let token = link.token {
                self = .signIn(record, TokenPayload(token: token, server: server))
            } else {
                self = .place(record.id, link)
            }
        } else {
            self = .addServer(TokenPayload(token: link.token ?? "", server: server), place: link)
        }
    }

    /// A tapped reminder's message, as a link to it on its saved server; nil once the server is gone.
    public init?(_ reminder: ReminderKey, records: [ServerRecord]) {
        guard let record = records.first(where: { $0.id == reminder.server }) else { return nil }
        self = .place(record.id, ApronLink(server: record.url, room: reminder.roomID, message: reminder.messageID))
    }
}
