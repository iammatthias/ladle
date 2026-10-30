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
    @State private var form = ConnectForm(record: nil, mayWrite: false, prefill: nil)
    @State private var scanning = false
    @State private var working = false
    @State private var error: String?
    @State private var session: ServerSession?
    @State private var showsOrigin = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text(existing?.serverName ?? record?.label ?? "Apron").apText(.display, .semibold).foregroundStyle(Palette.ink)
                        Text(record == nil ? "Connect to a server" : "Sign in again, or change this server")
                            .apText(.field).foregroundStyle(Palette.inkMuted)
                        if let description = existing?.server?.description {
                            EmojiText(text: MessageText.markdown(description, emoji: existing?.emojiCatalog), catalog: existing?.emojiCatalog, role: .ui)
                                .apText(.ui).foregroundStyle(Palette.inkMuted).tint(Palette.denim)
                                .written(in: TextDirection(of: description))
                                .task(id: existing?.server?.emojiCatalogURL) { await existing?.loadEmojiCatalog(for: description) }
                        }
                    }
                    if let greeter = session ?? existing, let welcome = greeter.server?.welcome {
                        Callout {
                            EmojiText(text: MessageText.markdown(welcome, emoji: greeter.emojiCatalog), catalog: greeter.emojiCatalog, role: .ui)
                                .tint(Palette.denim)
                                .written(in: TextDirection(of: welcome))
                        }
                        .task(id: greeter.server?.emojiCatalogURL) { await greeter.loadEmojiCatalog(for: welcome) }
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
                        TextField("", text: $form.address, prompt: Text("wss://chat.example/ws").foregroundStyle(Palette.inkMuted))
                            .apText(.ui, mono: true)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } hint: {
                        if !form.address.isEmpty, form.url == nil { Text("Enter a ws:// or wss:// address.").foregroundStyle(Palette.danger) }
                        if record == nil { HostYourOwnLink().padding(.leading, -Tokens.Space.s3) }
                    }
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Text("Sign in with").apText(.sm, .semibold).foregroundStyle(Palette.inkMuted)
                        Picker("Sign in with", selection: $form.method) {
                            ForEach(methods) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(minHeight: Tokens.Size.touchTarget)
                    }
                    methodFields
                    DisclosureGroup("Name and origin", isExpanded: $showsOrigin) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                            field("Name") {
                                TextField("", text: $form.label, prompt: Text(form.url.map(ServerRecord.defaultLabel(for:)) ?? "Name").foregroundStyle(Palette.inkMuted))
                                    .apText(.field)
                            } hint: { EmptyView() }
                            field("Origin") {
                                TextField("", text: $form.origin, prompt: Text("https://chat.example").foregroundStyle(Palette.inkMuted))
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
                    if working { ProgressView() } else {
                        Button(form.submitLabel(pendingEmail: pendingEmail)) { submit() }.disabled(!form.canSubmit(pendingEmail: pendingEmail)).fontWeight(.semibold)
                    }
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                QRScanner { text in
                    guard let fill = SignInFill(text, signingInTo: record?.url) else { return false }
                    form.apply(fill)
                    scanning = false
                    return true
                }
            }
            .sensoryFeedback(.success, trigger: form.receivedToken) { _, new in new != nil }
            .onAppear { form = ConnectForm(record: record, mayWrite: existing?.mayWrite == true, prefill: prefill) }
            .onChange(of: methods) { _, offered in form.offer(offered) }
        }
        .presentationBackground(Palette.chrome)
    }

    // MARK: Fields

    @ViewBuilder
    private var methodFields: some View {
        switch form.method {
        case .token:
            field("Token") {
                SecureField("", text: $form.token, prompt: Text("From the server, or a sign-in link").foregroundStyle(Palette.inkMuted))
                    .apText(.ui, mono: true)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } hint: {
                if let otherServer = form.otherServer {
                    Label("This link is for \(otherServer.host() ?? otherServer.absoluteString).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Palette.danger)
                } else if record != nil, form.tokenReceived {
                    Label("Token received", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                }
                if form.isSignUpInvite {
                    Text("This invitation creates an account. Choose the name others see, or leave it empty and the server picks one.")
                } else {
                    Text("Signed in elsewhere? In that app, send /invite-device add, or name the device, such as /invite-device add phone, then paste the token here or scan its QR code. A server's admin can also give you one.")
                }
                HStack(spacing: Tokens.Space.s2) {
                    PasteButton(payloadType: String.self) { strings in if let first = strings.first { form.accept(first) } }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                    if record != nil, canScan {
                        Button("Scan QR Code", systemImage: "qrcode.viewfinder") { scanning = true }
                            .buttonStyle(GhostButtonStyle(tone: Palette.accent))
                    }
                }
            }
            if form.isSignUpInvite {
                field("Your name") {
                    TextField("", text: $form.accountName, prompt: Text("How others see you").foregroundStyle(Palette.inkMuted))
                        .apText(.field)
                        .textContentType(.name)
                } hint: { EmptyView() }
            }
        case .email:
            if let pending = pendingEmail {
                field("Code") {
                    TextField("", text: $form.code, prompt: Text("From the email").foregroundStyle(Palette.inkMuted))
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
                    TextField("", text: $form.email, prompt: Text("you@example.com").foregroundStyle(Palette.inkMuted))
                        .apText(.field)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } hint: { EmptyView() }
            }
        case .guest:
            Text("No token needed. The server picks a guest name for you, such as Guest 12. Signing out of a guest account loses it.")
                .apText(.sm).foregroundStyle(Palette.inkMuted)
        }
    }

    /// The two ways to add a server: scan a sign-in QR code, which fills in the server and the
    /// token, or enter them in the fields below. Once a token is in, it says so instead.
    @ViewBuilder
    private var scanOrEnter: some View {
        if form.tokenReceived {
            ActionBanner(symbol: "checkmark", title: "Token received",
                         detail: form.url.flatMap { $0.host() }.map { "For \($0). Check the server, then tap Connect." } ?? "Enter the server's address, then tap Connect.",
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
        let chosen = form.url == OfficialServer.url
        return Button {
            form.address = OfficialServer.url.absoluteString
            form.method = .guest
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

    private var methods: [ConnectForm.Method] { ConnectForm.methods(offered: (session ?? existing)?.server) }

    /// The address a code was sent to, while the sheet waits for it.
    private var pendingEmail: String? { (session ?? existing)?.pendingEmail }

    // MARK: Submit

    private func submit() {
        guard let url = form.url else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            let session = store.save(form.saved(at: url))
            self.session = session
            for _ in 0 ..< 200 where session.server == nil || session.status == .connecting {
                if case .stopped = session.status { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard session.server != nil else {
                error = ConnectionState(session.status)?.title(session.record) ?? "Could not reach \(url.host() ?? "the server")."
                return
            }
            guard let signIn = form.signIn(pendingEmail: session.pendingEmail) else { return }
            do {
                if case .signedIn = try await session.signIn(signIn) {
                    onSignedIn(session.record.id)
                    dismiss()
                }
            } catch {
                self.error = errorText(error)
            }
        }
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
