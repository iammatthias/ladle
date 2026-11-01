import Foundation

/// A bio (extension `ext:bio`, `ext.bio`) as clients send and show it, as apron-web's `cleanBio`:
/// plain text, never markup, without what would change how it and the text around it read.
public enum Bio {
    /// The longest bio, in code points, so an emoji counts as one.
    public static let maxLength = 250

    /// Line feeds for line breaks, tabs as spaces, no control characters but the line feed and
    /// no bidi embeddings, overrides or isolates (U+202A–U+202E, U+2066–U+2069), no spaces
    /// before a line break, at most one blank line in a row, trimmed, and cut to `maxLength`.
    public static func clean(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
        for scalar in unified.unicodeScalars {
            switch scalar.value {
            case 0x0A: scalars.append(scalar)
            case 0x0D, 0x2028, 0x2029: scalars.append("\n")
            case 0x09: scalars.append(" ")
            case 0x00 ... 0x1F, 0x7F ... 0x9F, 0x202A ... 0x202E, 0x2066 ... 0x2069: continue
            default: scalars.append(scalar)
            }
        }
        var clean = String(scalars)
        while clean.contains(" \n") { clean = clean.replacingOccurrences(of: " \n", with: "\n") }
        while clean.contains("\n\n\n") { clean = clean.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.unicodeScalars.count > maxLength else { return clean }
        let cut = String(String.UnicodeScalarView(clean.unicodeScalars.prefix(maxLength)))
        return String(cut.reversed().drop { $0.isWhitespace }.reversed())
    }

    /// The bio a user object carries, cleaned; nil without one, for a value that is not a string,
    /// or a blank one, as a cleared bio is.
    public static func of(_ user: JSONValue?) -> String? {
        guard let bio = user?["ext"]?["bio"]?.stringValue else { return nil }
        let clean = clean(bio)
        return clean.isEmpty ? nil : clean
    }

    /// How long a draft is, as the field counts it.
    public static func length(_ draft: String) -> Int { draft.unicodeScalars.count }
}

/// A status you can choose with `me` (§4.5), as apron-web's picker lists them: `online` (the
/// default) and `""` (none) every server takes; `dnd` and `invisible` only where `server.status`
/// lists them (§4.5.1).
public struct StatusChoice: Hashable, Sendable, Identifiable {
    public let value: String
    public let label: String
    public let hint: String
    public var id: String { value }

    public static let all = [
        StatusChoice(value: "online", label: "Online", hint: "Automatic"),
        StatusChoice(value: "dnd", label: "Do not disturb", hint: "Mutes notifications"),
        StatusChoice(value: "invisible", label: "Invisible", hint: "Appear offline"),
        StatusChoice(value: "", label: "None", hint: "Show no status"),
    ]

    /// The statuses a server accepts only when `server.status` lists them.
    public static let optional: Set<String> = ["dnd", "invisible"]

    /// What the picker offers, in `all`'s order: Online and None always, Do not disturb and
    /// Invisible where the server accepts them and has not answered something else for them, and
    /// the current status (absent: `online`), so it shows as chosen.
    public static func offered(accepted: [String], unsupported: Set<String>, current: String?) -> [StatusChoice] {
        let shown = current ?? "online"
        return all.filter { choice in
            choice.value == shown || !optional.contains(choice.value) || (accepted.contains(choice.value) && !unsupported.contains(choice.value))
        }
    }

    /// A chosen status in words: "Online", "None", or an unknown value as itself.
    public static func label(_ status: String?) -> String {
        all.first { $0.value == (status ?? "") }?.label ?? (status ?? "")
    }

    /// What the current status means for how others see you, under the picker.
    public static func hint(for status: String?) -> String {
        switch status ?? "online" {
        case "online": "Others see you online, idle or offline, as you come and go."
        case "dnd": "Others see Do not disturb while you’re connected, and offline otherwise. Your notifications are silenced."
        case "invisible": "Others see you as offline."
        case "": "Others see no status."
        default: "Set by the server. Choose another to replace it."
        }
    }
}

/// What the server answered for a chosen status when it is not what was asked (§4.5: a server
/// may set another value), as apron-web's StatusPicker says it.
public struct StatusAnswer: Hashable, Sendable {
    public let title: String
    public let text: String

    /// Nil when the server kept the status asked for.
    public init?(asked: String, kept: String?) {
        guard (kept ?? "online") != asked else { return nil }
        title = StatusChoice.optional.contains(asked)
            ? "This server doesn’t offer \(StatusChoice.label(asked))"
            : "The server chose another status"
        text = "Your status is \(kept.map(StatusChoice.label) ?? "unchanged")."
    }

    /// The server refused it, so nothing changed (§4.5.3).
    public init(asked: String, error: String) {
        title = "Your status didn’t change"
        text = "The server declined \(StatusChoice.label(asked))\(error.isEmpty ? "" : " (\(error))")."
    }
}

/// The You sheet's name and bio, as apron-web's ProfileEditor: what you typed, what the server
/// keeps, and what it did with the last save.
public struct ProfileForm: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case none
        case saved
        /// The server kept another name than the one asked for (§1.1: servers may normalize).
        case altered(String)
        /// The server refused the name; the old one stays.
        case declined(String)
    }

    public var name: String
    public var bio: String
    public private(set) var openedName: String
    public private(set) var openedBio: String
    public var outcome = Outcome.none
    public var bioError: String?

    /// Starts from what the server keeps for you: your name and your bio.
    public init(you: UserObject?) {
        name = you?.json["name"]?.stringValue ?? ""
        bio = Bio.of(you?.json) ?? ""
        openedName = name
        openedBio = bio
    }

    /// Whether the name, or the bio where the server keeps one, differs from what it keeps:
    /// Save and Revert show.
    public func isDirty(keepsBio: Bool) -> Bool {
        trimmed(name) != trimmed(openedName) || (keepsBio && trimmed(bio) != trimmed(openedBio))
    }

    public var bioIsOver: Bool { Bio.length(bio) > Bio.maxLength }

    /// Back to what the server keeps.
    public mutating func revert() {
        name = openedName
        bio = openedBio
        bioError = nil
        outcome = .none
    }

    mutating func kept(name: String) {
        self.name = name
        openedName = name
    }

    mutating func kept(bio: String) {
        self.bio = bio
        openedBio = bio
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension ServerSession {
    /// Whether the server keeps a bio: it names `ext:bio`, or `ext`, which keeps any key.
    public var keepsBio: Bool { server?.has("ext:bio") == true || server?.has("ext") == true }

    /// The line under your name in the profile bar, as apron-web's: "Paused until 14:30" while
    /// your notifications are paused, else your status in words (the connection's while your dot
    /// is the dashed ring), else your `@user_id`.
    public var profileLine: String? {
        you.map { pausedLine ?? ownPresenceWords ?? Presence.words(chosenStatus, yours: true) ?? "@\($0.userID)" }
    }

    /// How this account signs in here, for the You sheet: first the nudge to add a way back in
    /// where it has none the server signs in with (apron-web's ProfileBar hint).
    public var signInWords: String {
        if let wayBack { return WayBack.hint(wayBack, signedInWithToken: record.account?.scheme == "token") }
        switch record.account?.scheme {
        case "guest": return "You’re a guest here. Sign in to keep your name and rooms."
        case "email": return "You sign in to this account with a code sent to your email."
        case "webauthn": return "You sign in to this account with a passkey."
        case "external": return "You sign in to this account on the server’s sign-in page."
        case "link": return "You signed in with a link, from an email or the server’s sign-in page."
        default: return "This device signs in with a token, the only way back into this account here."
        }
    }

    /// The profile bar's line under your name while the nudge stands, in place of your status
    /// (apron-web's `note`, "add a sign-in", capitalized as its ProfileBar shows it).
    public var profileNote: String? { wayBack == nil ? nil : "Add a sign-in" }

    /// Whether you can choose a status (§4.5): capability `status`, signed in.
    public var maySetStatus: Bool { server?.has("status") == true && status == .signedIn && you != nil }

    /// The statuses the picker offers you now.
    public var statusChoices: [StatusChoice] {
        StatusChoice.offered(accepted: server?.status ?? [], unsupported: unsupportedStatuses, current: chosenStatus)
    }

    /// Changes your profile with `me` (§3.3.2), which merges as a current object does. The
    /// result's `you` is complete and replaces what is kept. Returns it.
    @discardableResult
    public func updateProfile(_ changes: [String: JSONValue]) async throws -> UserObject {
        let result = try await request("me", .object(changes))
        guard let identity = UserObject(result["you"]) else { throw Failure.notSignedIn }
        adopt(identity)
        return identity
    }

    /// Chooses your status with `me` (§4.5). Returns what the server answered when it is not
    /// what was asked; an optional status it answered otherwise for is not offered again.
    public func chooseStatus(_ asked: String) async -> StatusAnswer? {
        do {
            try require("status")
            let kept = try await updateProfile(["status": .string(asked)]).json["status"]?.stringValue
            let answer = StatusAnswer(asked: asked, kept: kept)
            if answer != nil, StatusChoice.optional.contains(asked) { unsupportedStatuses.insert(asked) }
            return answer
        } catch let error as RPCError {
            return StatusAnswer(asked: asked, error: error.message)
        } catch {
            return StatusAnswer(asked: asked, error: "")
        }
    }

    /// Removes your avatar with `me {avatar: ""}` (§3.3.2). Returns false when the server kept it.
    public func removeAvatar() async throws -> Bool {
        let kept = try await updateProfile(["avatar": ""])
        return (kept.json["avatar"]?.stringValue ?? "").isEmpty
    }

    /// Saves the form as apron-web's ProfileEditor does: a changed bio first (`ext: {bio}`, `""`
    /// clearing it), then a changed name, and says what the server kept. A refused bio stops
    /// there and says why.
    public func save(_ form: ProfileForm) async -> ProfileForm {
        var form = form
        let requested = form.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty, form.isDirty(keepsBio: keepsBio) else { return form }
        form.outcome = .none
        form.bioError = nil
        let bio = Bio.clean(form.bio)
        if keepsBio, bio != form.openedBio {
            do {
                let kept = try await updateProfile(["ext": ["bio": .string(bio)]])
                form.kept(bio: Bio.of(kept.json) ?? "")
            } catch let error as RPCError {
                form.bioError = error.code == RPCError.Code.tooLarge ? "Your bio is too long for this server. Try a shorter one." : error.message
                return form
            } catch {
                form.bioError = "The server didn’t keep your bio."
                return form
            }
        }
        guard requested != form.openedName.trimmingCharacters(in: .whitespacesAndNewlines) else {
            form.outcome = .saved
            return form
        }
        do {
            let kept = try await updateProfile(["name": .string(requested)]).json["name"]?.stringValue ?? requested
            form.kept(name: kept)
            form.outcome = kept == requested ? .saved : .altered(kept)
        } catch {
            let reason = (error as? RPCError)?.message ?? ""
            form.outcome = .declined("The server declined this name\(reason.isEmpty ? "" : " (\(reason))"). Your old one is still in use.")
        }
        return form
    }
}
