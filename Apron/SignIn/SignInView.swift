import ApronKit
import SwiftUI

/// Signs in to one server with the schemes it offers: a token from another client first, then an
/// emailed code, then guest access.
struct SignInView: View {
    let session: ServerSession
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var email = ""
    @State private var code = ""
    @State private var guestName = ""
    @State private var scanning = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let welcome = session.server?.welcome {
                    Section { Text((try? AttributedString(markdown: welcome)) ?? AttributedString(welcome)) }
                }
                if let reason = session.signInNeeded {
                    Section { Label(reason, systemImage: "exclamationmark.triangle") }
                }
                if offers("token") { tokenSection }
                if offers("email") { emailSection }
                if offers("guest") { guestSection }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .disabled(working)
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $scanning) {
                QRScannerView { scanned in
                    scanning = false
                    token = scanned
                }
                .ignoresSafeArea()
            }
            .onChange(of: session.status) {
                if session.status == .signedIn { dismiss() }
            }
        }
    }

    private func offers(_ scheme: String) -> Bool {
        guard let server = session.server else { return false }
        return server.auth.contains(scheme) || (server.signup ?? []).contains(scheme)
    }

    private var tokenSection: some View {
        Section {
            TextField("Token or sign-in link", text: $token, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())
            HStack {
                PasteButton(payloadType: String.self) { strings in
                    if let first = strings.first { token = first }
                }
                .labelStyle(.titleAndIcon)
                if QRScannerView.isAvailable {
                    Button("Scan", systemImage: "qrcode.viewfinder") { scanning = true }
                        .buttonStyle(.bordered)
                }
            }
            Button("Sign In with Token") {
                guard let payload = TokenPayload(parsing: token) else {
                    error = "That is not a token or a sign-in link."
                    return
                }
                run { try await session.signIn(.token(payload.token)) }
            }
            .disabled(token.isEmpty)
        } header: {
            Text("Token")
        } footer: {
            Text("Paste or scan a token from another client, such as one a server's /invite-bot command gave you. It must come from the origin set for this server (\(session.record.origin)).")
        }
    }

    private var emailSection: some View {
        Section {
            if let pending = session.pendingEmail {
                Text("A code was sent to \(pending).")
                TextField("Code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                Button("Verify Code") { run { try await session.signIn(.emailCode(code.trimmingCharacters(in: .whitespaces))) } }
                    .disabled(code.isEmpty)
            } else {
                TextField("Email address", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Send Code") { run { try await session.signIn(.emailProposal(address: email.trimmingCharacters(in: .whitespaces))) } }
                    .disabled(email.isEmpty)
            }
        } header: {
            Text("Email")
        } footer: {
            Text("Keep this screen open: the code works only on the connection that asked for it.")
        }
    }

    private var guestSection: some View {
        Section("Guest") {
            TextField("Name (optional)", text: $guestName)
            Button("Join as Guest") { run { try await session.signIn(.guest(name: guestName)) } }
        }
    }

    private func run(_ operation: @escaping () async throws -> SignInOutcome) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                if case .signedIn = try await operation() { dismiss() }
            } catch {
                self.error = errorText(error)
            }
        }
    }
}
