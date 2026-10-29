import ApronKit
import SwiftUI

/// Adds a server and signs in to it in one sheet, as the web's ConnectScreen: the Apron
/// project's demo server as one tap or any server's address with a pointer to hosting your own,
/// "Sign in with" Token, Email or Guest, and the fields for that method. Opened for a
/// saved server, it signs in again and can change the name and origin. Adding a server, a
/// scanned, pasted or tapped sign-in link fills in the address and the token together; nothing
/// connects until you tap Connect (link.apron.chat SPEC §6).
struct ConnectView: View {
    let store: SessionStore
    var record: ServerRecord?
    var prefill: TokenPayload?
    /// Whether the camera can scan; the design-review renderer sets it, the app never does.
    var canScan = QRScanner.isAvailable
    /// Called with the server's id once a sign-in succeeds, just before the sheet closes.
    var onSignedIn: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var label = ""
    @State private var origin = ""
    @State private var method = Method.token
    @State private var token = ""
    @State private var email = ""
    @State private var code = ""
    @State private var guestName = ""
    @State private var scanning = false
    /// The token a scan, paste or link filled in, while the field still holds it.
    @State private var receivedToken: String?
    @State private var otherServer: URL?
    @State private var working = false
    @State private var error: String?
    @State private var session: ServerSession?
    @State private var showsOrigin = false

    enum Method: String, CaseIterable, Identifiable {
        case token = "Token", email = "Email", guest = "Guest"
        var id: String { rawValue }
        var scheme: String { rawValue.lowercased() }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text(record?.label ?? "Apron").apText(.display, .semibold).foregroundStyle(Palette.ink)
                        Text(record == nil ? "Connect to a server" : "Sign in again, or change this server")
                            .apText(.field).foregroundStyle(Palette.inkMuted)
                    }
                    if let welcome = session?.server?.welcome ?? existing?.server?.welcome {
                        Callout { Text((try? AttributedString(markdown: welcome)) ?? AttributedString(welcome)) }
                    }
                    if let reason = existing?.signInNeeded {
                        ActionBanner(symbol: "person.crop.circle.badge.exclamationmark", title: "Signed out", detail: reason, tone: Palette.warn) { EmptyView() }
                    }
                    if record == nil {
                        scanOrEnter
                        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                            Text("Official server").apText(.sm, .semibold).foregroundStyle(Palette.inkMuted)
                            officialServer
                        }
                    }
                    field(record == nil ? "Or your own server" : "Server") {
                        TextField("", text: $address, prompt: Text("wss://chat.example/ws").foregroundStyle(Palette.inkMuted))
                            .apText(.ui, mono: true)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: address) { old, new in
                                let previous = Self.url(from: old).map(ServerRecord.defaultOrigin(for:)) ?? ""
                                guard origin.isEmpty || origin == previous else { return }
                                origin = Self.url(from: new).map(ServerRecord.defaultOrigin(for:)) ?? ""
                            }
                    } hint: {
                        if !address.isEmpty, url == nil { Text("Enter a ws:// or wss:// address.").foregroundStyle(Palette.danger) }
                        if record == nil { HostYourOwnLink().padding(.leading, -Tokens.Space.s3) }
                    }
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text("Sign in with").apText(.sm, .semibold).foregroundStyle(Palette.inkMuted)
                        Picker("Sign in with", selection: $method) {
                            ForEach(methods) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(minHeight: Tokens.Size.touchTarget)
                    }
                    methodFields
                    DisclosureGroup("Name and origin", isExpanded: $showsOrigin) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                            field("Name") {
                                TextField("", text: $label, prompt: Text(url.map(ServerRecord.defaultLabel(for:)) ?? "Name").foregroundStyle(Palette.inkMuted))
                                    .apText(.field)
                            } hint: { EmptyView() }
                            field("Origin") {
                                TextField("", text: $origin, prompt: Text("https://chat.example").foregroundStyle(Palette.inkMuted))
                                    .apText(.ui, mono: true)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            } hint: {
                                Text("A token works only from the website that gave it to you. If yours came from a web client at another address, such as https://web.apron.chat, enter that address here.")
                            }
                        }
                        .padding(.top, Tokens.Space.s2)
                    }
                    .apText(.ui, .semibold)
                    .tint(Palette.inkMuted)
                    .foregroundStyle(Palette.inkMuted)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle").apText(.ui).foregroundStyle(Palette.danger)
                    }
                }
                .padding(Tokens.Space.s6)
                .background(Palette.timeline, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(Palette.line))
                .frame(maxWidth: 400)
                .padding(Tokens.Space.s4)
                .frame(maxWidth: .infinity)
            }
            .background(Palette.chrome)
            .disabled(working)
            .navigationTitle(record == nil ? "Add Server" : "Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working { ProgressView() } else { Button(submitLabel) { submit() }.disabled(!canSubmit).fontWeight(.semibold) }
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                QRScanner { text in
                    guard let fill = SignInFill(text, signingInTo: record?.url) else { return false }
                    apply(fill)
                    scanning = false
                    return true
                }
            }
            .sensoryFeedback(.success, trigger: receivedToken) { _, new in new != nil }
            .onAppear(perform: load)
            .onChange(of: methods) { _, offered in if !offered.contains(method), let first = offered.first { method = first } }
        }
        .presentationBackground(Palette.chrome)
    }

    // MARK: Fields

    @ViewBuilder
    private var methodFields: some View {
        switch method {
        case .token:
            field("Token") {
                SecureField("", text: $token, prompt: Text("From the server, or a sign-in link").foregroundStyle(Palette.inkMuted))
                    .apText(.ui, mono: true)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: token) { _, new in
                        if new.contains("token=") { accept(new) } else if !new.isEmpty { otherServer = nil }
                    }
            } hint: {
                if let otherServer {
                    Label("This link is for \(otherServer.host() ?? otherServer.absoluteString).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Palette.danger)
                } else if record != nil, tokenReceived {
                    Label("Token received", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                }
                Text("Signed in elsewhere? In that app, send /invite-device and a name, such as /invite-device phone, then paste the token here or scan its QR code. A server's admin can also give you one.")
                HStack(spacing: Tokens.Space.s2) {
                    PasteButton(payloadType: String.self) { strings in if let first = strings.first { accept(first) } }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                    if record != nil, canScan {
                        Button("Scan QR Code", systemImage: "qrcode.viewfinder") { scanning = true }
                            .buttonStyle(GhostButtonStyle(tone: Palette.accent))
                    }
                }
            }
        case .email:
            if let pending = (session ?? existing)?.pendingEmail {
                field("Code") {
                    TextField("", text: $code, prompt: Text("From the email").foregroundStyle(Palette.inkMuted))
                        .apText(.field, mono: true)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } hint: {
                    Text("If \(pending) can sign in here, a code is on its way. Enter it, or paste the link from the email. Keep this sheet open until you do.")
                }
            } else {
                field("Email") {
                    TextField("", text: $email, prompt: Text("you@example.com").foregroundStyle(Palette.inkMuted))
                        .apText(.field)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } hint: { EmptyView() }
            }
        case .guest:
            field("Display name") {
                TextField("", text: $guestName, prompt: Text("How others see you").foregroundStyle(Palette.inkMuted))
                    .apText(.field)
                    .textContentType(.nickname)
            } hint: {
                Text("No token needed; the server picks a guest identity. Signing out of a guest account loses it.")
            }
        }
    }

    /// The two ways to add a server: scan a sign-in QR code, which fills in the server and the
    /// token, or enter them in the fields below. Once a token is in, it says so instead.
    @ViewBuilder
    private var scanOrEnter: some View {
        if tokenReceived {
            ActionBanner(symbol: "checkmark", title: "Token received",
                         detail: url.flatMap { $0.host() }.map { "For \($0). Check the server, then tap Connect." } ?? "Enter the server's address, then tap Connect.",
                         tone: Palette.ok) {
                if canScan {
                    Button("Scan Again") { scanning = true }.buttonStyle(GhostButtonStyle(tone: Palette.accent))
                }
            }
        } else if canScan {
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                Button { scanning = true } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                Text("Fills in the server and token from a sign-in code, such as the one /invite-device sends.")
                    .apText(.sm).foregroundStyle(Palette.inkMuted)
                HStack(spacing: Tokens.Space.s2) {
                    Rectangle().fill(Palette.line).frame(height: 1)
                    Text("or enter manually").apText(.sm, .semibold).foregroundStyle(Palette.inkMuted).fixedSize()
                    Rectangle().fill(Palette.line).frame(height: 1)
                }
                .accessibilityElement(children: .combine)
                .padding(.top, Tokens.Space.s1)
            }
        }
    }

    /// The Apron project's demo server as one tap, styled as the web's recent-backend row: it
    /// fills in the address (the origin follows) and picks Guest, which needs nothing else.
    private var officialServer: some View {
        let chosen = url == OfficialServer.url
        return Button {
            address = OfficialServer.url.absoluteString
            method = .guest
        } label: {
            HStack(spacing: Tokens.Space.s3) {
                RailTile(label: OfficialServer.label, active: chosen)
                VStack(alignment: .leading, spacing: 1) {
                    Text(OfficialServer.label).apText(.body, .medium).foregroundStyle(Palette.ink)
                    Text("Public demo, run by the Apron project").apText(.sm).foregroundStyle(Palette.inkMuted)
                    Text(OfficialServer.url.host() ?? "").apText(.sm, mono: true).foregroundStyle(Palette.inkMuted)
                }
                Spacer(minLength: Tokens.Space.s2)
                if chosen { Image(systemName: "checkmark").foregroundStyle(Palette.accent).accessibilityHidden(true) }
            }
            .padding(Tokens.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(chosen ? Palette.selected : Palette.timeline, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(chosen ? Palette.accent : Palette.lineStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// The web's `ap-fieldlabel` over an `ap-field`.
    private func field<Field: View, Hint: View>(_ title: String, @ViewBuilder _ content: () -> Field, @ViewBuilder hint: () -> Hint) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(title).apText(.sm, .semibold).foregroundStyle(Palette.inkMuted)
            content()
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, Tokens.Space.s2)
                .frame(minHeight: Tokens.Size.touchTarget)
                .background(Palette.timeline, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.lineStrong))
            hint().apText(.sm).foregroundStyle(Palette.inkMuted)
        }
    }

    // MARK: State

    private var existing: ServerSession? { record.flatMap { store.session(for: $0.id) } }

    /// The methods the server offers, once it has said; all three until then.
    private var methods: [Method] {
        guard let server = (session ?? existing)?.server else { return Method.allCases }
        let offered = Set(server.auth + (server.signup ?? []))
        let known = Method.allCases.filter { offered.contains($0.scheme) }
        return known.isEmpty ? Method.allCases : known
    }

    private var url: URL? { Self.url(from: address) }

    private var tokenReceived: Bool { method == .token && receivedToken == token }

    private var submitLabel: String {
        switch method {
        case .email where (session ?? existing)?.pendingEmail == nil: "Send Code"
        default: record == nil ? "Connect" : "Sign In"
        }
    }

    private var canSubmit: Bool {
        guard url != nil else { return false }
        switch method {
        case .token: return TokenPayload(parsing: token) != nil
        case .email: return (session ?? existing)?.pendingEmail == nil ? email.contains("@") : !code.isEmpty
        case .guest: return true
        }
    }

    static func url(from address: String) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil
        else { return nil }
        return url
    }

    private func load() {
        if let record {
            address = record.url.absoluteString
            label = record.label
            origin = record.origin
            if let scheme = record.account?.scheme, let saved = Method(rawValue: scheme.capitalized),
               saved != .guest || existing?.isReadOnlyGuest == false {
                method = saved
            }
        }
        if let prefill { accept(prefill) }
    }

    /// Pasted or typed text: a sign-in fills in, anything else lands in the field as typed.
    private func accept(_ text: String) {
        guard let fill = SignInFill(text, signingInTo: record?.url) else {
            token = text
            return
        }
        apply(fill)
    }

    /// A link that opened Ladle, which may name a server with no token.
    private func accept(_ payload: TokenPayload) {
        if let server = payload.server, record == nil { address = server.absoluteString }
        if !payload.token.isEmpty { apply(.token(payload.token)) }
    }

    private func apply(_ fill: SignInFill) {
        otherServer = nil
        switch fill {
        case .serverAndToken(let server, let token):
            address = server.absoluteString
            apply(.token(token))
        case .token(let token):
            self.token = token
            receivedToken = token
            method = .token
        case .otherServer(let server):
            token = ""
            otherServer = server
            method = .token
        }
    }

    // MARK: Submit

    private func submit() {
        guard let url else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            let session = save(url)
            self.session = session
            for _ in 0 ..< 200 where session.server == nil || session.status == .connecting {
                if case .stopped = session.status { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard session.server != nil else {
                error = ConnectionState(session.status)?.title(session.record) ?? "Could not reach \(url.host() ?? "the server")."
                return
            }
            do {
                let outcome: SignInOutcome
                switch method {
                case .token:
                    guard let payload = TokenPayload(parsing: token) else { return }
                    outcome = try await session.signIn(.token(payload.token))
                case .email:
                    if session.pendingEmail == nil {
                        outcome = try await session.signIn(.emailProposal(address: email.trimmingCharacters(in: .whitespaces)))
                    } else if let payload = TokenPayload(parsing: code), code.contains("token=") {
                        outcome = try await session.signIn(.token(payload.token))
                    } else {
                        outcome = try await session.signIn(.emailCode(code.trimmingCharacters(in: .whitespaces)))
                    }
                case .guest:
                    outcome = try await session.signIn(.guest(name: guestName))
                }
                if case .signedIn = outcome {
                    onSignedIn(session.record.id)
                    dismiss()
                }
            } catch {
                self.error = errorText(error)
            }
        }
    }

    /// Adds the server, or saves changes to it, and returns its session.
    private func save(_ url: URL) -> ServerSession {
        var saved = record ?? ServerRecord(url: url)
        saved.url = url
        let name = label.trimmingCharacters(in: .whitespaces)
        let trimmedOrigin = origin.trimmingCharacters(in: .whitespaces)
        saved.label = name.isEmpty ? ServerRecord.defaultLabel(for: url) : name
        saved.origin = trimmedOrigin.isEmpty ? ServerRecord.defaultOrigin(for: url) : trimmedOrigin
        if let existing = store.session(for: saved.id) {
            if existing.record.url != saved.url || existing.record.origin != saved.origin || existing.record.label != saved.label {
                Task { await store.update(saved) }
            }
            return existing
        }
        return store.add(saved)
    }
}

/// The public demo server the Apron project runs: apron-web's default server
/// (`VITE_DEFAULT_SERVER_URL` in its `.env.production`). Ladle runs no server of its own.
enum OfficialServer {
    static let url = URL(string: "wss://server.apron.chat/")!
    static let label = "Apron Demo"
    /// The Apron project's server, for hosting your own.
    static let selfHosting = URL(string: "https://github.com/apron-chat/apron-server-go")!
}
