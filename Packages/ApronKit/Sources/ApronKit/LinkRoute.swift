import Foundation

/// Where an Apron link that reaches the app, or a tapped reminder, goes (link.apron.chat SPEC):
/// a sign-in link with the `state` of this device's own proposal continues it on the server it
/// went to, whatever `server` the link names (§2.1); any other sign-in link for a saved server
/// asks first (`SignInLinkPrompt`), since it never signs in by itself (§6); a place on a saved
/// server opens; and a link to another server opens the Connect sheet to add it, which opens the
/// place once signed in.
public enum LinkRoute: Hashable, Sendable {
    /// The link answers `proposal`, a sign-in or an addition this device made.
    case proposal(Proposal, token: String)
    case signIn(ServerRecord, TokenPayload)
    case place(UUID, ApronLink)
    case addServer(TokenPayload, place: ApronLink)

    /// Nil for a link without a server: a relative link has no server that sent it here.
    /// `proposal` is this device's proposal with the link's `state` (`Proposals.find`).
    public init?(_ link: ApronLink, records: [ServerRecord], proposal: Proposal? = nil) {
        if let token = link.token, let proposal, records.contains(where: { $0.id == proposal.server }) {
            self = .proposal(proposal, token: token)
            return
        }
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
