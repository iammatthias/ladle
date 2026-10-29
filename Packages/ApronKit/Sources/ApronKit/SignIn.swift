import Foundation

/// One `auth` request a user can make (§3.2, §4.11). Email sign-in is two requests on the same
/// connection: a proposal, then approval with the code the server mailed, which works only on the
/// connection that proposed (§4.11.2).
public enum SignIn: Hashable, Sendable {
    /// A bearer token from another client, such as one `/invite-bot` issued (§3.2.1).
    case token(String)
    /// A sign-up invite (`/invite` on Cloudflare's demo, an `apron_join_` token): it creates an
    /// account named `name`, and the result carries that account's own token, which is saved.
    case signUp(invite: String, name: String)
    case guest(name: String?)
    case emailProposal(address: String)
    case emailCode(String)

    public var scheme: String {
        switch self {
        case .token, .signUp: "token"
        case .guest: "guest"
        case .emailProposal, .emailCode: "email"
        }
    }

    /// Whether a successful reply carries `you`. A proposal authenticates nothing (§4.11.1).
    public var authenticates: Bool {
        if case .emailProposal = self { return false }
        return true
    }

    /// The `auth` params. `state` goes only on a proposal (§4.11.1).
    public func params(agent: String, state: String) -> JSONValue {
        var params: [String: JSONValue] = ["scheme": .string(scheme), "agent": .string(agent)]
        switch self {
        case .token(let token): params["token"] = .string(token)
        case .signUp(let invite, let name):
            params["token"] = .string(invite)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { params["name"] = .string(trimmed) }
        case .guest(let name): if let name, !name.isEmpty { params["name"] = .string(name) }
        case .emailProposal(let address):
            params["email"] = .string(address)
            params["state"] = .string(state)
        case .emailCode(let code): params["token"] = .string(code)
        }
        return .object(params)
    }
}

extension SignIn {
    /// Whether a token is a sign-up invite, which creates an account rather than signing in to one.
    public static func isSignUpInvite(_ token: String) -> Bool { token.hasPrefix("apron_join_") }
}

public enum SignInOutcome: Hashable, Sendable {
    case signedIn(UserObject)
    /// The server mailed a code; approve it with `.emailCode` on the same connection.
    case codeSent(to: String)
}

/// A token as a user pastes or scans it: the bare token, or a sign-in link (link.apron.chat SPEC
/// §2.1) whose `token` key holds it, such as `https://link.apron.chat/#server=wss://chat.example/ws&token=…`.
/// An `apron:` URI never carries one (`ApronLink`).
public struct TokenPayload: Hashable, Sendable {
    public var token: String
    /// The link's `server`, when it named one.
    public var server: URL?

    public init(token: String, server: URL? = nil) {
        self.token = token
        self.server = server
    }

    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = ApronLink(trimmed) {
            guard let token = link.token else { return nil }
            self.init(token: token, server: link.server)
            return
        }
        guard OpaqueID.isValid(trimmed), !trimmed.lowercased().hasPrefix("apron:"), !trimmed.lowercased().hasPrefix("https://") else { return nil }
        self.init(token: trimmed)
    }
}

/// What a scanned or pasted sign-in fills in on the Connect sheet, which never signs in by itself
/// (link.apron.chat SPEC §6). `signingInTo` is the saved server the sheet signs in to, or nil
/// when it adds one; a link may name a new server only then.
public enum SignInFill: Hashable, Sendable {
    case serverAndToken(server: URL, token: String)
    case token(String)
    /// A link for a server other than the saved one the sheet signs in to.
    case otherServer(URL)

    /// Nil when the text is neither a token nor a sign-in link. A token is opaque, so any other
    /// URI (a web page, `WIFI:…`, `mailto:…`) would otherwise pass as a bare one.
    public init?(_ text: String, signingInTo current: URL?) {
        guard let payload = TokenPayload(parsing: text) else { return nil }
        if payload.server == nil, payload.token.prefixMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:/) != nil { return nil }
        switch (payload.server, current) {
        case (nil, _): self = .token(payload.token)
        case (let server?, nil): self = .serverAndToken(server: server, token: payload.token)
        case (let server?, let current?): self = server == current ? .token(payload.token) : .otherServer(server)
        }
    }
}
