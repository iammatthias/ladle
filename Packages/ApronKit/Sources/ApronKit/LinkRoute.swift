import Foundation

/// Where an Apron link that reaches the app, or a tapped reminder, goes (link.apron.chat SPEC):
/// a sign-in link with the `state` of this device's own proposal continues it on the server it
/// went to, whatever `server` the link names (§2.1); any other sign-in link for a saved server
/// asks first (`SignInLinkPrompt`), since it never signs in by itself (§6); a place on a saved
/// server opens; and a link to another server opens the Connect sheet to add it, which opens the
/// place once signed in.
///
/// A server with several saved accounts has a record per account, so a link naming it has to
/// pick one. A place link takes the one account that can see the place, else the open record
/// (`preferred`) when it is one of them, else asks (`chooseAccount`). A sign-in link always asks
/// which account it is for, or whether it signs in a new one: a token says nothing about whose
/// it is, and using it signs the chosen account out.
public enum LinkRoute: Hashable, Sendable {
    /// The link answers `proposal`, a sign-in or an addition this device made.
    case proposal(Proposal, token: String)
    case signIn(ServerRecord, TokenPayload)
    case place(UUID, ApronLink)
    case addServer(TokenPayload, place: ApronLink)
    /// Several saved accounts on the link's server could take it: the user picks.
    case chooseAccount(AccountChoice)

    /// Nil for a link without a server: a relative link has no server that sent it here.
    /// `proposal` is this device's proposal with the link's `state` (`Proposals.find`);
    /// `preferred` the record open on screen; `sees` whether a record's session can show the
    /// link's place (`ServerSession.placeCard`).
    public init?(_ link: ApronLink, records: [ServerRecord], proposal: Proposal? = nil, preferred: UUID? = nil,
                 sees: (UUID) -> Bool = { _ in true }) {
        if let token = link.token, let proposal, records.contains(where: { $0.id == proposal.server }) {
            self = .proposal(proposal, token: token)
            return
        }
        guard let server = link.server else { return nil }
        let accounts = records.filter { $0.url == server }
        guard let first = accounts.first else {
            self = .addServer(TokenPayload(token: link.token ?? "", server: server), place: link)
            return
        }
        if let token = link.token {
            let payload = TokenPayload(token: token, server: server)
            self = accounts.count == 1 ? .signIn(first, payload) : .chooseAccount(AccountChoice(link: link, token: token, accounts: accounts))
            return
        }
        let seeing = accounts.filter { sees($0.id) }
        let pool = seeing.isEmpty ? accounts : seeing
        if pool.count == 1 {
            self = .place(pool[0].id, link)
        } else if let preferred, pool.contains(where: { $0.id == preferred }) {
            self = .place(preferred, link)
        } else {
            self = .chooseAccount(AccountChoice(link: link, token: nil, accounts: pool))
        }
    }

    /// A tapped reminder's message, as a link to it on its saved server; nil once the server is gone.
    public init?(_ reminder: ReminderKey, records: [ServerRecord]) {
        guard let record = records.first(where: { $0.id == reminder.server }) else { return nil }
        self = .place(record.id, ApronLink(server: record.url, room: reminder.roomID, message: reminder.messageID))
    }
}

/// The accounts a link could go to, for the user to pick one: the saved records on the link's
/// server that could take it, and for a sign-in link the choice of a new account as well.
public struct AccountChoice: Hashable, Sendable {
    public let link: ApronLink
    /// The sign-in link's token; nil for a place.
    public let token: String?
    public let accounts: [ServerRecord]

    public init(link: ApronLink, token: String?, accounts: [ServerRecord]) {
        self.link = link
        self.token = token
        self.accounts = accounts
    }

    public var host: String { link.server?.host() ?? link.server?.absoluteString ?? "" }

    /// "Open on home.example as…", or "Sign in to home.example as…".
    public var title: String {
        token == nil ? "Open on \(host) as…" : "Sign in to \(host) as…"
    }

    /// A sign-in link may be for an account not saved yet: adding one on the server, with the
    /// token filled in, is a choice too. Nil for a place.
    public var newAccount: TokenPayload? { token.map { TokenPayload(token: $0, server: link.server) } }

    /// The row for a new account: "Sign In as a New Account".
    public static let newAccountLabel = "Sign In as a New Account"

    /// Where the link goes once `id` is picked: the sign-in prompt for that record, or the place.
    public func route(_ id: UUID) -> LinkRoute? {
        guard let record = accounts.first(where: { $0.id == id }) else { return nil }
        if let token { return .signIn(record, TokenPayload(token: token, server: link.server)) }
        return .place(id, link)
    }
}

extension AccountChoice: Identifiable {
    public var id: AccountChoice { self }
}
