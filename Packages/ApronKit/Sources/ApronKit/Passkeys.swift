import Foundation

/// A passkey ceremony (§4.10): `register` creates a passkey (a new account for a guest, another
/// passkey for an account), `login` signs in with one.
public enum PasskeyAction: String, Sendable, Hashable {
    case register, login
}

/// Unpadded base64url, WebAuthn JSON's encoding of binary fields.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Also takes padded or plain base64, as some servers write it.
    public static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.replacingOccurrences(of: "=", with: "")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// Why a passkey ceremony did not run or did not finish, in the words the app shows.
public enum PasskeyError: Error, Hashable, Sendable {
    /// The begin step's result had no usable `public_key`.
    case invalidOptions
    /// The server's address names no host.
    case noHost
    /// The server asked for a passkey of a domain that is not its own (§4.10, apron-web #183).
    case foreignRelyingParty(host: String, rpID: String)
    /// The domain is not one of the app's `webcredentials` associated domains, so iOS would refuse
    /// the request with a generic error.
    case notAssociated(rpID: String)
    /// The platform writes `https://<rpID>` into `clientDataJSON`, and the server binds the
    /// ceremony and the token it issues to the connection's `Origin`, so the two must agree.
    case originMismatch(origin: String, rpID: String)
    /// The server lists no `webauthn` where this ceremony needs it.
    case notOffered
    /// The system sheet was dismissed.
    case cancelled
    /// The connection the ceremony began on went away before it finished.
    case connectionChanged
    /// The platform failed for another reason, in its words.
    case failed(String)

    public var message: String {
        switch self {
        case .invalidOptions: "Invalid passkey options from server"
        case .noHost: "Passkeys need a server address with a host name."
        case .foreignRelyingParty(let host, let rpID): "This server (\(host)) asked for a passkey for \(rpID.isEmpty ? "no domain" : rpID), which is not its own."
        case .notAssociated(let rpID): PasskeyDomains.unavailableWords(for: rpID)
        case .originMismatch(let origin, let rpID): "Passkeys for \(rpID) sign in from https://\(rpID), but this server is set to the origin \(origin). Change the origin under Name and Origin, then try again."
        case .notOffered: "This server does not support passkeys"
        case .cancelled: "Cancelled."
        case .connectionChanged: "Connection changed; try again"
        case .failed(let reason): reason
        }
    }
}

/// The domains this build may use passkeys for: its `webcredentials` associated domains, which
/// the build writes from `APRON_ASSOCIATED_DOMAINS` into both the entitlements and the
/// Info.plist key `LadlePasskeyDomains`, since an app cannot read its entitlements at run time.
public struct PasskeyDomains: Hashable, Sendable {
    public let domains: [String]

    /// Space- or comma-separated, each a host or `*.host` for its subdomains.
    public init(_ list: String) {
        domains = list.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map { $0.lowercased() }
    }

    public static let none = PasskeyDomains("")

    /// This app's list, from its Info.plist.
    public static var app: PasskeyDomains {
        PasskeyDomains(Bundle.main.object(forInfoDictionaryKey: "LadlePasskeyDomains") as? String ?? "")
    }

    /// Whether a passkey for `rpID` can be asked for: it is an associated domain, or under a
    /// `*.` one (which, as Apple's wildcard, does not cover the domain itself).
    public func covers(_ rpID: String) -> Bool {
        let rpID = rpID.lowercased()
        return domains.contains { domain in
            if domain.hasPrefix("*.") { return rpID.hasSuffix(domain.dropFirst(1)) }
            return domain == rpID
        }
    }

    /// Whether a passkey for the server at `url` could be asked for: its host, or a domain the
    /// host is under, is covered. The RP ID itself comes only with a ceremony's begin step.
    public func covers(server url: URL) -> Bool {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        var labels = host.split(separator: ".")
        if covers(host) { return true }
        while labels.count > 2 {
            labels.removeFirst()
            if covers(labels.joined(separator: ".")) { return true }
        }
        return false
    }

    /// What the sign-in sheet says where passkeys exist but this app can't use them: a passkey
    /// works only in a web client on its domain and the apps the domain's association file lists.
    public static func unavailableWords(for rpID: String) -> String {
        "Ladle can’t use passkeys for \(rpID): only apps that domain lists can. Sign in with your passkey in a web browser, get a token for this device there (such as with /invite-device add), and paste it here."
    }
}

/// A begin step's result (§4.10): what the platform needs to make the passkey or find one.
public struct PasskeyChallenge: Hashable, Sendable {
    public struct User: Hashable, Sendable {
        /// The WebAuthn user handle.
        public var id: Data
        public var name: String
        public var displayName: String
    }

    public var action: PasskeyAction
    public var challengeID: String
    /// Lowercased, and checked to be the server's host or a domain it is under.
    public var rpID: String
    public var challenge: Data
    /// Registration only.
    public var user: User?
    /// Registration: the account's passkeys, which the platform won't make again.
    public var excludedCredentials: [Data]
    /// Login: empty for a discoverable credential (§4.10), which every server sends.
    public var allowedCredentials: [Data]
    /// `required`, `preferred` or `discouraged`; §4.10 requires verification.
    public var userVerification: String

    /// Reads `result` and runs apron-web's `passkeyRpIdError`: the RP ID is `rp.id` when
    /// registering and `rpId` when signing in, and the other field does not count. Without one,
    /// the web takes its page's host; a native app has none, so this takes the server's host.
    public init(result: JSONValue, action: PasskeyAction, server: URL) throws {
        guard let challengeID = result["challenge_id"]?.stringValue, !challengeID.isEmpty,
              let publicKey = result["public_key"], publicKey.objectValue != nil,
              let challenge = publicKey["challenge"]?.stringValue.flatMap(Base64URL.decode)
        else { throw PasskeyError.invalidOptions }
        guard let host = server.host()?.lowercased(), !host.isEmpty else { throw PasskeyError.noHost }
        let requested = action == .register ? publicKey["rp"]?["id"]?.stringValue : publicKey["rpId"]?.stringValue
        let rpID = (requested ?? host).lowercased()
        guard !rpID.isEmpty, host == rpID || host.hasSuffix("." + rpID) else {
            throw PasskeyError.foreignRelyingParty(host: host, rpID: rpID)
        }
        func ids(_ list: JSONValue?) -> [Data] {
            (list?.arrayValue ?? []).compactMap { $0["id"]?.stringValue.flatMap(Base64URL.decode) }
        }
        self.action = action
        self.challengeID = challengeID
        self.rpID = rpID
        self.challenge = challenge
        if action == .register {
            guard let user = publicKey["user"], let id = user["id"]?.stringValue.flatMap(Base64URL.decode) else {
                throw PasskeyError.invalidOptions
            }
            let name = user["name"]?.stringValue ?? ""
            self.user = User(id: id, name: name, displayName: user["displayName"]?.stringValue ?? name)
            userVerification = publicKey["authenticatorSelection"]?["userVerification"]?.stringValue ?? "required"
        } else {
            user = nil
            userVerification = publicKey["userVerification"]?.stringValue ?? "required"
        }
        excludedCredentials = ids(publicKey["excludeCredentials"])
        allowedCredentials = ids(publicKey["allowCredentials"])
    }

    /// The checks before the system sheet opens, after the RP ID's: the app must be associated
    /// with the domain, and the connection's origin must be the one the platform signs.
    public func check(domains: PasskeyDomains, origin: String) throws {
        guard domains.covers(rpID) else { throw PasskeyError.notAssociated(rpID: rpID) }
        let expected = "https://" + rpID
        guard origin.lowercased().trimmingSuffix("/") == expected else {
            throw PasskeyError.originMismatch(origin: origin, rpID: rpID)
        }
    }

    /// The name a new passkey is saved under, as apron-web's `labelledCreationOptions`: the
    /// account's name where one is given, since a server fills `user.name` from the session the
    /// ceremony starts on (a guest's).
    public func passkeyName(labelled label: String?) -> String {
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? (user?.name ?? "") : label
    }
}

extension String {
    fileprivate func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}

/// What the platform hands back, as raw bytes, and its WebAuthn JSON for the finish step.
public enum PasskeyCredential: Hashable, Sendable {
    case registration(id: Data, clientDataJSON: Data, attestationObject: Data, attachment: Attachment?)
    case assertion(id: Data, clientDataJSON: Data, authenticatorData: Data, signature: Data, userHandle: Data?, attachment: Attachment?)

    public enum Attachment: String, Hashable, Sendable {
        case platform
        case crossPlatform = "cross-platform"
    }

    /// `PublicKeyCredential.toJSON()`'s shape: every binary field unpadded base64url, an empty
    /// `clientExtensionResults`, and `authenticatorAttachment` when the platform says.
    public var json: JSONValue {
        let id: Data
        var response: [String: JSONValue]
        let attachment: Attachment?
        switch self {
        case .registration(let credentialID, let clientData, let attestation, let platform):
            id = credentialID
            attachment = platform
            response = ["clientDataJSON": .string(Base64URL.encode(clientData)),
                        "attestationObject": .string(Base64URL.encode(attestation))]
        case .assertion(let credentialID, let clientData, let authenticatorData, let signature, let userHandle, let platform):
            id = credentialID
            attachment = platform
            response = ["clientDataJSON": .string(Base64URL.encode(clientData)),
                        "authenticatorData": .string(Base64URL.encode(authenticatorData)),
                        "signature": .string(Base64URL.encode(signature))]
            if let userHandle { response["userHandle"] = .string(Base64URL.encode(userHandle)) }
        }
        var credential: [String: JSONValue] = [
            "id": .string(Base64URL.encode(id)),
            "rawId": .string(Base64URL.encode(id)),
            "type": "public-key",
            "response": .object(response),
            "clientExtensionResults": .object([:]),
        ]
        if let attachment { credential["authenticatorAttachment"] = .string(attachment.rawValue) }
        return .object(credential)
    }
}

/// The platform's passkey sheet. The app's is `ASAuthorizationController`; tests use a software
/// authenticator. It runs one ceremony, started by the user's tap.
public protocol PasskeyAuthenticator: Sendable {
    /// Makes a passkey named `name`, or finds one, for `challenge`. Throws `PasskeyError.cancelled`
    /// when the user dismisses the sheet.
    @MainActor func credential(for challenge: PasskeyChallenge, name: String) async throws -> PasskeyCredential
}
