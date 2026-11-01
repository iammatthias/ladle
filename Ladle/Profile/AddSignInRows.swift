import ApronKit
import AuthenticationServices
import SwiftUI

/// Ways back into the signed-in account, as apron-web's Profile sign-in rows: Add Passkey, Add
/// Email (address, then the emailed code) and Add External Sign-In (the server's page, which
/// comes back to add itself, or shows a code), each where the server signs in with it. Each is
/// proposed and approved on the signed-in connection (§4.11.1); a link of no addition here never
/// adds, it signs in.
struct AddSignInRows: View {
    let session: ServerSession
    @State private var adding: Adding?

    init(session: ServerSession, adding: Adding? = nil) {
        self.session = session
        _adding = State(initialValue: adding)
    }
    @State private var busy = false
    @State private var notice: String?
    @State private var problem: String?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    struct Adding: Equatable {
        var scheme: ProposalScheme
        var email = ""
        var code = ""
        var codeSent = false

        init(scheme: ProposalScheme, email: String = "", code: String = "", codeSent: Bool = false) {
            self.scheme = scheme
            self.email = email
            self.code = code
            self.codeSent = codeSent
        }
    }

    private var offered: [String] { session.server?.auth ?? [] }

    var body: some View {
        if busy, adding == nil {
            Label("Confirm on your device…", systemImage: "person.badge.key").apText(.ui).foregroundStyle(Palette.inkMuted)
        }
        if adding == nil {
            if offered.contains("webauthn") {
                Button("Add Passkey", systemImage: "person.badge.key") { addPasskey() }
                    .disabled(busy || session.status != .signedIn || !session.passkeysUsable)
                if !session.passkeysUsable, let host = session.record.url.host() {
                    Text(PasskeyDomains.unavailableWords(for: host)).formFooter()
                }
            }
            if offered.contains("email") {
                Button("Add Email", systemImage: "envelope") { adding = Adding(scheme: .email) }
                    .disabled(busy || session.status != .signedIn)
            }
            if offered.contains("external") {
                Button("Add External Sign-In", systemImage: "safari") { addExternal() }
                    .disabled(busy || session.status != .signedIn)
            }
        } else if let form = adding {
            addForm(form)
        }
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle").apText(.sm).foregroundStyle(Palette.danger)
        } else if let notice {
            Label(notice, systemImage: "checkmark.circle").apText(.sm).foregroundStyle(Palette.ok)
        }
    }

    @ViewBuilder
    private func addForm(_ form: Adding) -> some View {
        if form.scheme == .email, !form.codeSent {
            TextField("Email address to add", text: binding(\.email), prompt: Text("you@example.com"))
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(proceed)
            Button("Send Code", action: proceed).disabled(busy || form.email.trimmingCharacters(in: .whitespaces).isEmpty)
        } else {
            TextField(form.scheme == .email ? "Code from the email" : "Code from the sign-in page", text: binding(\.code), prompt: Text("Code"))
                .textContentType(.oneTimeCode)
                .keyboardType(form.scheme == .email ? .numberPad : .asciiCapable)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(proceed)
            if form.scheme == .email {
                Text("If the server can send to \(form.email), a code is on its way.").formFooter()
            } else if let page = session.pendingAddition?.page {
                Button("Open the Sign-In Page", systemImage: "safari") { Task { await open(page, returns: false) } }
                Text("Sign in there, then enter the code it shows you.").formFooter()
            }
            Button("Add", action: proceed).disabled(busy || form.code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Button("Cancel", role: .cancel) { adding = nil }.disabled(busy)
    }

    private func binding(_ key: WritableKeyPath<Adding, String>) -> Binding<String> {
        Binding { adding?[keyPath: key] ?? "" } set: { adding?[keyPath: key] = $0 }
    }

    private func run(_ work: @escaping () async throws -> Void, scheme: String) {
        busy = true
        problem = nil
        notice = nil
        Task {
            defer { busy = false }
            do { try await work() } catch PasskeyError.cancelled {
                problem = "Cancelled."
            } catch {
                problem = additionErrorText(error, scheme: scheme)
            }
        }
    }

    private func addPasskey() {
        run({
            try await session.usePasskey(.register, with: PlatformPasskeys())
            notice = "Passkey saved. This server will ask your device next time."
        }, scheme: "webauthn")
    }

    private func proceed() {
        guard let form = adding, !busy else { return }
        run({
            if form.scheme == .email, !form.codeSent {
                _ = try await session.proposeAddition(.email, email: form.email)
                adding?.codeSent = true
            } else {
                try await session.approveAddition(code: form.code)
                adding = nil
                notice = form.scheme == .email ? "Added \(form.email.trimmingCharacters(in: .whitespaces)) · sign in with it anywhere" : "Added · sign in with it anywhere"
            }
        }, scheme: form.scheme.rawValue)
    }

    private func addExternal() {
        run({
            guard case .page(let page, let returns) = try await session.proposeAddition(.external) else { return }
            if !returns { adding = Adding(scheme: .external, codeSent: true) }
            await open(page, returns: returns)
        }, scheme: "external")
    }

    /// The server's page; one that comes back with this addition's link adds it.
    private func open(_ page: URL, returns: Bool) async {
        do {
            switch try await ExternalSignIn.open(page, returns: returns, origin: session.record.origin, proposals: session.proposals,
                                                 session: webAuthenticationSession) {
            case .link(let token, let proposal) where proposal.kind == .addition:
                try await session.approveAddition(link: token, proposal: proposal)
                adding = nil
                notice = "Added · sign in with it anywhere"
            case .link, .foreignLink:
                problem = ExternalSignIn.foreignWords
            case .closed:
                break
            }
        } catch {
            problem = additionErrorText(error, scheme: "external")
        }
    }
}
