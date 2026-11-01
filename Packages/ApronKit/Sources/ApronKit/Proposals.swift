import Foundation

/// A way in that finishes outside the connection (§4.11).
public enum ProposalScheme: String, Sendable, Hashable, CaseIterable {
    case email, external
}

/// An email or external proposal this device made (§4.11.1), remembered by its `state` so a link
/// that comes back with it is known for its own, as apron-web's `proposals.ts`: which server it
/// went to, and whether it signs in or adds to an account.
public struct Proposal: Hashable, Sendable {
    public enum Kind: String, Sendable, Hashable {
        /// Approves on a connection not signed in.
        case signIn = "sign-in"
        /// Approves only on a connection signed in to `account`.
        case addition
    }

    public var scheme: ProposalScheme
    public var kind: Kind
    /// The saved server it went to; a link's token is for it alone.
    public var server: UUID
    public var state: String
    public var email: String?
    /// For an addition, the `user_id` of the account that proposed it.
    public var account: String?
    public var expires: Date

    public init(scheme: ProposalScheme, kind: Kind, server: UUID, state: String, email: String? = nil, account: String? = nil, expires: Date) {
        self.scheme = scheme
        self.kind = kind
        self.server = server
        self.state = state
        self.email = email
        self.account = account
        self.expires = expires
    }
}

/// The proposals still current, in `proposals.json` beside `servers.json`: an email link opens
/// the app after it may have been closed. apron-web keeps 8 for an hour (`PROPOSAL_KEPT_MS`): a
/// proposal expires within minutes, which leaves room for slow mail and a long sign-in page.
@MainActor
public final class Proposals {
    public static let kept = 8
    public static let lifetime: TimeInterval = 60 * 60

    private var entries: [Proposal] = []
    private let fileURL: URL?

    /// `directory` nil keeps them in memory only.
    public init(directory: URL? = nil) {
        fileURL = directory?.appending(path: "proposals.json")
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let json = try? JSONValue(parsing: data) else { return }
        entries = (json.arrayValue ?? []).compactMap(Self.read)
    }

    public func remember(_ proposal: Proposal, now: Date) {
        entries = current(now).filter { $0.state != proposal.state } + [proposal]
        if entries.count > Self.kept { entries.removeFirst(entries.count - Self.kept) }
        save()
    }

    /// The current proposal with this `state`, if this device made it.
    public func find(_ state: String?, now: Date) -> Proposal? {
        guard let state, !state.isEmpty else { return nil }
        return current(now).first { $0.state == state }
    }

    /// Approval used it up (§4.11.1), or it was never sent.
    public func forget(_ state: String) {
        guard entries.contains(where: { $0.state == state }) else { return }
        entries.removeAll { $0.state == state }
        save()
    }

    public func removeAll(server: UUID) {
        guard entries.contains(where: { $0.server == server }) else { return }
        entries.removeAll { $0.server == server }
        save()
    }

    private func current(_ now: Date) -> [Proposal] { entries.filter { $0.expires > now } }

    private func save() {
        guard let fileURL else { return }
        let json = JSONValue.array(entries.map { entry in
            var object: [String: JSONValue] = ["scheme": .string(entry.scheme.rawValue), "kind": .string(entry.kind.rawValue),
                                               "server": .string(entry.server.uuidString), "state": .string(entry.state),
                                               "expires": .number(String(Int(entry.expires.timeIntervalSince1970)))]
            if let email = entry.email { object["email"] = .string(email) }
            if let account = entry.account { object["account"] = .string(account) }
            return .object(object)
        })
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.serializedData().write(to: fileURL, options: .atomic)
    }

    private static func read(_ entry: JSONValue) -> Proposal? {
        guard let scheme = entry["scheme"]?.stringValue.flatMap(ProposalScheme.init(rawValue:)),
              let kind = entry["kind"]?.stringValue.flatMap(Proposal.Kind.init(rawValue:)),
              let server = entry["server"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let state = entry["state"]?.stringValue,
              let expires = entry["expires"]?.doubleValue
        else { return nil }
        return Proposal(scheme: scheme, kind: kind, server: server, state: state, email: entry["email"]?.stringValue,
                        account: entry["account"]?.stringValue, expires: Date(timeIntervalSince1970: expires))
    }
}

/// What a sign-in link is for (§4.11.2), as apron-web's `linkUse`: a sign-in this device proposed,
/// used at once on the server it went to; an addition this device proposed, for the account that
/// proposed it; or any other link, used only once the user confirms.
public enum LinkUse: Hashable, Sendable {
    case own(token: String, proposal: Proposal)
    case addition(token: String, proposal: Proposal)
    case ask(token: String, server: URL)

    @MainActor
    public init(token: String, state: String?, server: URL, proposals: Proposals, now: Date) {
        if let proposal = proposals.find(state, now: now) {
            self = proposal.kind == .addition && proposal.account != nil ? .addition(token: token, proposal: proposal) : .own(token: token, proposal: proposal)
        } else {
            self = .ask(token: token, server: server)
        }
    }
}

/// The confirmation before a link of no proposal here is used, as apron-web's
/// `signInLinkPrompt`: which server, what it replaces, and the warning that a link from someone
/// else signs in to their account. A link doesn't say whether it signs in or adds a sign-in
/// (§4.11.1), so where an account is signed in on the link's server the dialog also offers to
/// add it there (`adds`). That is safe: an addition approves only on a connection signed in to
/// the account that proposed it, and a sign-in's token is refused on one (§4.11.3).
public struct SignInLinkPrompt: Hashable, Sendable {
    public var title: String
    public var lines: [String]
    public var adds: Bool

    /// `host` names the link's server. `addAs` is the account signed in there, guests included;
    /// `keptSession` whether a session is kept there that has not resumed.
    public init(host: String, addAs: String?, keptSession: Bool) {
        if let addAs {
            title = "Use this link on \(host)?"
            lines = [
                "If you asked to add this way of signing in to \(addAs), on this device or another, add it.",
                "If you asked to sign in with it, signing in signs you out of \(addAs) and in to the account the link is for.",
                "Only sign in if you just asked to, on this device or another. A link someone sent you can sign you in to their account.",
            ]
            adds = true
            return
        }
        title = "Sign in to \(host) with this link?"
        lines = keptSession ? ["You have a saved session here. Continuing signs you out of it."] : []
        lines.append(Self.warning)
        adds = false
    }

    /// The warning before any link of no proposal here is used, also on the Connect sheet once a
    /// link has filled it in.
    public static let warning = "Only continue if you just asked to sign in, on this device or another. A link someone sent you can sign you in to their account."

    /// Why a link of no proposal here didn't sign in, as apron-web's `askedLinkFailure`.
    public static func failure(_ error: String) -> String {
        "The link didn’t sign you in (\(error)). If it was sent to add a way of signing in to an account, open it where you’re signed in to that account. Otherwise sign in again, or pick another server."
    }
}

/// The ways back in that can be added to an account (§4.10, §4.11), in the order suggested.
public enum AddableScheme: String, Sendable, Hashable, CaseIterable {
    case webauthn, email, external

    var words: String {
        switch self {
        case .webauthn: "a passkey"
        case .email: "an email"
        case .external: "an external sign-in"
        }
    }
}

/// The nudge to add a way back into an account (§3.2.1's SHOULD), as apron-web's `wayBackNudge`:
/// the passkey, email and external schemes the server signs in with, when none of the ways the
/// account is known to have (how it signed in, then what was added) is one of them. A `link`
/// method is an email or an external sign-in, not known which.
public enum WayBack {
    public static func suggested(auth: [String], methods: [String]) -> [AddableScheme]? {
        guard !methods.isEmpty else { return nil }
        let signsIn = AddableScheme.allCases.filter { auth.contains($0.rawValue) }
        let has = { (scheme: AddableScheme) in methods.contains(scheme.rawValue) || (scheme != .webauthn && methods.contains("link")) }
        guard !signsIn.isEmpty, !signsIn.contains(where: has) else { return nil }
        return signsIn
    }

    /// "a passkey or an email".
    public static func words(_ schemes: [AddableScheme]) -> String {
        let words = schemes.map(\.words)
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " or " + words[words.count - 1]
    }

    /// The Sign-in section's line, as the web's ProfileBar hint.
    public static func hint(_ schemes: [AddableScheme], signedInWithToken: Bool) -> String {
        (signedInWithToken ? "Only this device’s saved session gets you back into this account." : "This server doesn’t sign in the way you joined.")
            + " Add \(words(schemes)) to sign in anywhere."
    }
}

/// What went wrong adding an address or an external identity (§4.11.3), as apron-web's `addError`:
/// `denied` is usually one that belongs to another account already.
public func additionErrorText(_ error: any Error, scheme: String) -> String {
    if let error = error as? RPCError, error.code == RPCError.Code.denied {
        switch scheme {
        case "email": return "That code was refused: it may be wrong or expired, or the address may belong to another account. Ask for a new code, or sign in with that address instead."
        case "external": return "That was refused: the code may be wrong or expired, or that sign-in may belong to another account. Start again, or sign in with it instead."
        default: return "That link was refused: it may have expired or been used, be for signing in rather than adding, or be for another account, which it adds to only where that account is signed in. Open it again to sign in with it instead."
        }
    }
    return errorText(error)
}

/// The fragment of the URL an external page returns to (§4.11.2, §4.11.5):
/// `#token=…&state=…&server=…`, form-encoded. `server` is ignored: a link with this device's
/// `state` is for the server the proposal went to.
public struct SignInFragment: Hashable, Sendable {
    public var token: String
    public var state: String?

    public init(token: String, state: String?) {
        self.token = token
        self.state = state
    }

    public init?(_ url: URL) {
        guard let fragment = url.fragment(percentEncoded: true), !fragment.isEmpty else { return nil }
        var parts = URLComponents()
        parts.percentEncodedQuery = fragment.replacingOccurrences(of: "+", with: "%20")
        let items = parts.queryItems ?? []
        guard let token = items.first(where: { $0.name == "token" })?.value?.trimmingCharacters(in: .whitespaces), !token.isEmpty else { return nil }
        self.token = token
        state = items.first(where: { $0.name == "state" })?.value.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// An external sign-in page (§4.11.5): an absolute `https` URL, or `http` on a loopback host.
/// Anything else, such as `javascript:…`, is refused.
public enum SignInPage {
    public static func accepts(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
        default: return false
        }
    }

    /// Where the page sends the user back (`return_url`): the origin the connection presents,
    /// which a server trusts for its own web client, and which the app's
    /// `ASWebAuthenticationSession` can catch only where its host is an associated domain. Nil
    /// elsewhere: the page then shows a code to type here.
    public static func returnURL(origin: String, domains: PasskeyDomains) -> URL? {
        guard let url = URL(string: origin), url.scheme?.lowercased() == "https", let host = url.host(), url.port == nil,
              domains.covers(host)
        else { return nil }
        return URL(string: "https://\(host.lowercased())/")
    }
}
