import Foundation

/// An addition proposed on the signed-in connection (§4.11.1): only that connection approves it
/// with a code.
public struct PendingAddition: Hashable, Sendable {
    public var scheme: ProposalScheme
    /// The address an email addition went to.
    public var email: String?
    /// The page of an external addition that shows a code.
    public var page: URL?
    var state: String
    var connection: Int
}

/// Passkeys (§4.10), additions to an account (§4.11.1, §4.11.3) and sign-in links (§4.11.2), as
/// apron-web's `usePasskey`, `requestEmailCodeToAdd`, `proposeExternalToAdd`, `addWithCode`,
/// `addWithLink` and `signInWithLink`.
extension ServerSession {
    // MARK: Passkeys

    /// Whether passkeys can run here: the server offers `webauthn`, and this build is associated
    /// with the server's host or a domain it is under. The RP ID itself is known only once a
    /// ceremony begins, so a parent domain the app holds counts.
    public var passkeysUsable: Bool { environment.passkeyDomains.covers(server: record.url) }

    /// Whether the server offers passkeys for signing in (`auth`) or creating accounts (`signup`).
    public var offersPasskeys: (signIn: Bool, signUp: Bool) {
        guard let server else { return (false, false) }
        return (server.auth.contains("webauthn"), (server.signup ?? server.auth).contains("webauthn"))
    }

    /// A passkey account whose saved token the server refused, on a server that still takes
    /// passkeys: one tap signs back in (apron-web's "Sign in with your passkey to continue.").
    public var passkeyHold: Bool {
        guard you == nil, let held = heldAccount, held.methods.contains("webauthn") else { return false }
        return offersPasskeys.signIn
    }

    /// Runs one passkey ceremony, started by the user's tap. `login` signs in on a connection
    /// with no identity (a signed-in one is replaced first). `register` needs a signed-in
    /// connection, as servers make a guest's registration a new account under a new `user_id`
    /// (with `name`, which also labels the passkey) and add one to an account; signed out, it
    /// joins as a guest first. Both steps go on one connection, and a drop between them fails.
    @discardableResult
    public func usePasskey(_ action: PasskeyAction, name: String? = nil, with authenticator: any PasskeyAuthenticator) async throws -> UserObject {
        let offered = offersPasskeys
        guard action == .login ? offered.signIn : offered.signUp || offered.signIn else { throw PasskeyError.notOffered }
        let stopped = if case .stopped = status { true } else { false }
        if connection == nil || stopped || (action == .login && status == .signedIn) {
            try await connectAfresh()
        }
        if action == .register, status == .signedOut, let connection {
            _ = try await authenticate(.guest(name: nil), on: connection)
        }
        guard let connection else { throw Failure.notConnected }
        let number = connectionNumber
        let account = status == .signedIn && !isGuest ? record.account : nil
        let requested = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var begin: [String: JSONValue] = ["scheme": "webauthn", "action": .string(action.rawValue), "step": "begin",
                                          "agent": .string(environment.agent)]
        if action == .register, !requested.isEmpty { begin["name"] = .string(requested) }
        let options = try await connection.request("auth", params: .object(begin))
        let challenge = try PasskeyChallenge(result: options, action: action, server: record.url)
        try challenge.check(domains: environment.passkeyDomains, origin: record.origin)
        let label = requested.isEmpty ? you.flatMap { $0.json["name"]?.stringValue } : requested
        let credential = try await authenticator.credential(for: challenge, name: challenge.passkeyName(labelled: label))
        guard connection === self.connection, connectionNumber == number else { throw PasskeyError.connectionChanged }
        let finish: JSONValue = ["scheme": "webauthn", "action": .string(action.rawValue), "step": "finish",
                                 "challenge_id": .string(challenge.challengeID), "credential": credential.json,
                                 "agent": .string(environment.agent)]
        // Signing in, or a guest becoming an account, is followed by what follows a sign-in
        // (§4.5.4); a passkey added to an account changes no one.
        let signsIn = account == nil
        if signsIn { resetMutes() }
        let auth = try await connection.send("auth", params: finish)
        let rooms = signsIn ? try await connection.send("room_list", params: ["filter": "joined", "members": true]) : nil
        let result = try await auth.value
        guard let identity = UserObject(result["you"]) else { throw Failure.notSignedIn }
        if let account, action == .register {
            try await adoptSignIn(identity, result: result, method: account.scheme, presented: nil, registered: true, rooms: nil,
                                  on: connection, keepsState: true, added: account.added)
            noteAdded("webauthn")
        } else {
            try await adoptSignIn(identity, result: result, method: "webauthn", presented: nil, registered: true, rooms: rooms,
                                  on: connection, keepsState: action == .register)
        }
        return identity
    }

    // MARK: Additions

    /// Proposes adding an email address or an external identity to the signed-in account
    /// (§4.11.1), on this connection. An email addition sends a code; an external one returns
    /// the server's page, which comes back with a link where the app can catch its return,
    /// else shows a code.
    public func proposeAddition(_ scheme: ProposalScheme, email: String? = nil) async throws -> SignInOutcome {
        guard status == .signedIn, let you else { throw Failure.notSignedIn }
        guard server?.auth.contains(scheme.rawValue) == true else {
            throw PasskeyError.failed(scheme == .email ? "This server does not sign in with email, so an address can’t be added"
                                                         : "This server does not sign in with an external page, so none can be added")
        }
        let state = environment.makeState()
        let address = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        proposals.remember(Proposal(scheme: scheme, kind: .addition, server: record.id, state: state, email: address,
                                    account: you.userID, expires: environment.now().addingTimeInterval(Proposals.lifetime)),
                           now: environment.now())
        var params: [String: JSONValue] = ["scheme": .string(scheme.rawValue), "state": .string(state), "agent": .string(environment.agent)]
        let returnURL = scheme == .external ? SignInPage.returnURL(origin: record.origin, domains: environment.passkeyDomains) : nil
        if let address { params["email"] = .string(address) }
        if let returnURL { params["return_url"] = .string(returnURL.absoluteString) }
        let result: JSONValue
        do {
            result = try await request("auth", .object(params))
        } catch {
            proposals.forget(state)
            throw error
        }
        switch scheme {
        case .email:
            pendingAddition = PendingAddition(scheme: .email, email: address, state: state, connection: connectionNumber)
            return .codeSent(to: address ?? "")
        case .external:
            guard let page = result["url"]?.stringValue.flatMap(URL.init(string:)), SignInPage.accepts(page) else {
                proposals.forget(state)
                throw Failure.badSignInPage
            }
            pendingAddition = PendingAddition(scheme: .external, page: returnURL == nil ? page : nil, state: state, connection: connectionNumber)
            return .page(page, returns: returnURL != nil)
        }
    }

    /// Approves the open addition with its code, on the connection that proposed it (§4.11.3). A
    /// wrong code leaves it open to try again.
    public func approveAddition(code: String) async throws {
        guard let pending = pendingAddition, pending.connection == connectionNumber else { throw Failure.noAddition }
        _ = try await request("auth", ["scheme": .string(pending.scheme.rawValue), "token": .string(code.trimmingCharacters(in: .whitespacesAndNewlines))])
        proposals.forget(pending.state)
        pendingAddition = nil
        noteAdded(pending.scheme.rawValue)
    }

    /// Approves an addition with a link's token: one with the `state` of this device's addition,
    /// or one the user chose to add from the link dialog, sent with an addable scheme the server
    /// offers, since the link doesn't say which (§4.11.3).
    public func approveAddition(link token: String, proposal: Proposal?) async throws {
        let offered = ProposalScheme.allCases.filter { server?.auth.contains($0.rawValue) == true }
        guard let scheme = proposal?.scheme ?? offered.first else {
            throw PasskeyError.failed("This server does not sign in with email or an external page, so none can be added")
        }
        _ = try await request("auth", ["scheme": .string(scheme.rawValue), "token": .string(token)])
        if let proposal { proposals.forget(proposal.state) }
        if pendingAddition?.state == proposal?.state { pendingAddition = nil }
        noteAdded(proposal?.scheme.rawValue ?? (offered.count == 1 ? scheme.rawValue : "link"))
    }

    // MARK: Links

    /// Signs in with a link's token (§4.11.2): with this device's proposal, as its scheme;
    /// otherwise, once the user confirmed it, as `token`, remembered as a `link` where the server
    /// signs in with email or an external page (either may have sent it), else as a token, such
    /// as an invite's (apron-web's `linkMethod`).
    @discardableResult
    public func signIn(link token: String, proposal: Proposal?) async throws -> SignInOutcome {
        let linked = ProposalScheme.allCases.contains { server?.auth.contains($0.rawValue) == true }
        let outcome = try await signIn(proposal.map { .ownLink(token, scheme: $0.scheme) } ?? (linked ? .link(token) : .token(token)))
        if let proposal { proposals.forget(proposal.state) }
        return outcome
    }

    /// The account to add a link's sign-in to, for the link dialog: the one signed in here,
    /// guests included.
    public var linkAddAs: String? {
        guard status == .signedIn, let you else { return nil }
        return users.displayName(for: you)
    }

    /// The "add a sign-in" nudge (§3.2.1): for an account with a token to resume, not a guest.
    public var wayBack: [AddableScheme]? {
        guard resumable, !isGuest, let account = record.account, let server else { return nil }
        return WayBack.suggested(auth: server.auth, methods: account.methods)
    }
}
