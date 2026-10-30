import Foundation

/// The Connect sheet's form, as apron-web's ConnectScreen: a server's address, name and origin,
/// how to sign in (a token, email or guest) and that method's fields. Opened for a saved server it
/// signs in again and can change the name and origin. A scanned, pasted or tapped sign-in fills in
/// the address and the token together; nothing connects until the user submits (link.apron.chat
/// SPEC §6).
public struct ConnectForm: Sendable {
    public enum Method: String, CaseIterable, Identifiable, Sendable {
        case token = "Token", email = "Email", guest = "Guest"
        public var id: String { rawValue }
        public var scheme: String { rawValue.lowercased() }
    }

    /// The saved server being signed in to again; nil to add one.
    public let record: ServerRecord?
    /// The address the user typed: `ws://` or `wss://`. Setting it moves an origin that followed
    /// the old address to the new one's.
    public var address = "" {
        didSet {
            let previous = Self.url(from: oldValue).map(ServerRecord.defaultOrigin(for:)) ?? ""
            guard origin.isEmpty || origin == previous else { return }
            origin = url.map(ServerRecord.defaultOrigin(for:)) ?? ""
        }
    }
    public var label = ""
    public var origin = ""
    public var method = Method.token
    /// Typed or pasted. A pasted sign-in link fills the form in (`accept(_:)`).
    public var token = "" {
        didSet {
            if token.contains("token=") { accept(token) } else if !token.isEmpty { otherServer = nil }
        }
    }
    public var email = ""
    public var code = ""
    /// The name of the account a sign-up invite creates.
    public var accountName = ""
    /// The token a scan, paste or link filled in, while the field still holds it.
    public private(set) var receivedToken: String?
    /// A sign-in link for a server other than the saved one.
    public private(set) var otherServer: URL?

    /// The form for `record`, or for a new server with `record` nil, with what a link filled in.
    /// A saved server signs in again by its last method, unless that was a guest the server now
    /// lets only read (`mayWrite` false).
    public init(record: ServerRecord?, mayWrite: Bool, prefill: TokenPayload?) {
        self.record = record
        if let record {
            address = record.url.absoluteString
            label = record.label
            origin = record.origin
            if let scheme = record.account?.scheme, let saved = Method(rawValue: scheme.capitalized), saved != .guest || mayWrite {
                method = saved
            }
        }
        if let prefill { accept(prefill) }
    }

    public static func url(from address: String) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil
        else { return nil }
        return url
    }

    public var url: URL? { Self.url(from: address) }

    /// The methods `server` offers (`auth` and `signup`), once it has said; all three until then,
    /// or when it names none of them.
    public static func methods(offered server: ServerInfo?) -> [Method] {
        guard let server else { return Method.allCases }
        let offered = Set(server.auth + (server.signup ?? []))
        let known = Method.allCases.filter { offered.contains($0.scheme) }
        return known.isEmpty ? Method.allCases : known
    }

    /// Keeps the method among those offered, else takes the first.
    public mutating func offer(_ methods: [Method]) {
        if !methods.contains(method), let first = methods.first { method = first }
    }

    public var tokenReceived: Bool { method == .token && receivedToken == token }

    /// An `apron_join_` token: it creates an account, named as the user asks.
    public var isSignUpInvite: Bool { TokenPayload(parsing: token).map { SignIn.isSignUpInvite($0.token) } ?? false }

    /// The submit button's word, with `pendingEmail` the address a code was sent to.
    public func submitLabel(pendingEmail: String?) -> String {
        switch method {
        case .email where pendingEmail == nil: "Send Code"
        case .token where isSignUpInvite: "Create Account"
        default: record == nil ? "Connect" : "Sign In"
        }
    }

    public func canSubmit(pendingEmail: String?) -> Bool {
        guard url != nil else { return false }
        switch method {
        case .token: return TokenPayload(parsing: token) != nil
        case .email: return pendingEmail == nil ? email.contains("@") : !code.isEmpty
        case .guest: return true
        }
    }

    /// Pasted or typed text: a sign-in fills in, anything else lands in the token field as typed.
    public mutating func accept(_ text: String) {
        guard let fill = SignInFill(text, signingInTo: record?.url) else {
            if token != text { token = text }
            return
        }
        apply(fill)
    }

    /// A link that opened Ladle, which may name a server with no token.
    public mutating func accept(_ payload: TokenPayload) {
        if let server = payload.server, record == nil { address = server.absoluteString }
        if !payload.token.isEmpty { apply(.token(payload.token)) }
    }

    /// A scanned or pasted sign-in.
    public mutating func apply(_ fill: SignInFill) {
        otherServer = nil
        switch fill {
        case .serverAndToken(let server, let token):
            address = server.absoluteString
            apply(.token(token))
        case .token(let token):
            receivedToken = token
            self.token = token
            method = .token
        case .otherServer(let server):
            token = ""
            otherServer = server
            method = .token
        }
    }

    /// The `auth` to send. With `pendingEmail`, the email method sends the code, or the link
    /// from the email when that was pasted.
    public func signIn(pendingEmail: String?) -> SignIn? {
        switch method {
        case .token:
            guard let payload = TokenPayload(parsing: token) else { return nil }
            return SignIn.isSignUpInvite(payload.token) ? .signUp(invite: payload.token, name: accountName) : .token(payload.token)
        case .email:
            if pendingEmail == nil { return .emailProposal(address: email.trimmingCharacters(in: .whitespaces)) }
            if let payload = TokenPayload(parsing: code), code.contains("token=") { return .token(payload.token) }
            return .emailCode(code.trimmingCharacters(in: .whitespaces))
        case .guest:
            return .guest(name: nil)
        }
    }

    /// The server to save: the saved record, or a new one, at `url` with the name and origin
    /// given, each defaulting from the address when left empty.
    public func saved(at url: URL) -> ServerRecord {
        var saved = record ?? ServerRecord(url: url)
        saved.url = url
        let name = label.trimmingCharacters(in: .whitespaces)
        let trimmedOrigin = origin.trimmingCharacters(in: .whitespaces)
        saved.label = name.isEmpty ? ServerRecord.defaultLabel(for: url) : name
        saved.origin = trimmedOrigin.isEmpty ? ServerRecord.defaultOrigin(for: url) : trimmedOrigin
        return saved
    }
}

extension SessionStore {
    /// Adds the server, or saves changes to a saved one, and returns its session.
    @discardableResult
    public func save(_ record: ServerRecord) -> ServerSession {
        if let existing = session(for: record.id) {
            if existing.record.url != record.url || existing.record.origin != record.origin || existing.record.label != record.label {
                Task { await update(record) }
            }
            return existing
        }
        return add(record)
    }
}
