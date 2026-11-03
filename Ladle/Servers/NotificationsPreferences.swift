import ApronKit
import SwiftUI

/// Notifications, as apron-web's: the one Notifications switch for this device with the note on
/// how far it reaches, Send a test notification, and for each server Notify Me About (each
/// scope marked "Only while open" where push is on and the server doesn't push it), Pause
/// notifications, and, in a build with push, the relay that alerts while Ladle is closed.
struct NotificationsPreferences: View {
    let store: SessionStore
    let server: UUID?
    @State private var testing = false
    @State private var tested: NotifyTestResult?
    @Environment(\.openURL) private var openURL

    private var alerts: MessageAlerts { store.alerts }

    var body: some View {
        Form {
            Section {
                Toggle("Notifications", isOn: Binding(get: { alerts.isOn }, set: switchTo))
                    .disabled(!alerts.isOn && alerts.permission == .denied)
                if alerts.permission == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(settings) }
                }
                Button(testing ? "Sending…" : "Send a Test Notification") { sendTest() }
                    .disabled(testing || alerts.permission == .denied)
                if let tested {
                    Text(testWords(tested)).apText(.sm).foregroundStyle(tested == .sent ? Palette.ok : Palette.danger)
                }
            } footer: {
                Text(note).formFooter()
            }
            .listRowBackground(Palette.raised)
            ForEach(sessions(store, server), id: \.record.id) { session in
                ScopesSection(store: store, session: session, header: server == nil ? session.serverName : nil)
                if session.mayMute {
                    PauseSection(session: session, header: server == nil ? session.serverName : nil)
                }
            }
            if store.pushInBuild {
                RelaySection(store: store)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.chrome)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await alerts.refreshPermission() }
    }

    /// What the switch says under it, as apron-web's `notificationsNote`, in iOS's words.
    private var note: String {
        let reminders = " Reminders you set with Remind Me alert either way."
        if alerts.permission == .denied { return "Off in Settings. Allow notifications for Ladle there to turn them on." + reminders }
        guard alerts.isOn else { return (alerts.permission == .authorized ? "Off." : "iOS will ask for permission.") + reminders }
        return "On while Ladle is open, for the rooms you're not reading. Below, each server says whether it alerts when Ladle is closed." + reminders
    }

    private func switchTo(_ on: Bool) {
        Task {
            if on { await alerts.turnOn() } else { await alerts.turnOff() }
            await store.syncPush()
            await store.updateBadge()
        }
    }

    private func sendTest() {
        testing = true
        Task {
            tested = await alerts.sendTest()
            testing = false
        }
    }

    private func testWords(_ result: NotifyTestResult) -> String {
        switch result {
        case .sent: "Test notification sent. Check Notification Center."
        case .denied: "Notifications are off for Ladle. Allow them in Settings."
        case .failed: "iOS couldn't show the test notification."
        }
    }
}

/// apron-web's "Notify me about" for one account: at least one stays checked, and with push on,
/// a scope the server doesn't push says "Only while open". Its footer says whether this server
/// alerts while Ladle is closed, and why not.
private struct ScopesSection: View {
    let store: SessionStore
    let session: ServerSession
    var header: String?

    var body: some View {
        if let account = session.notifyAccount {
            let settings = store.alerts.settings
            let scopes = settings.scopes(of: account)
            let notes = NotifyScope.notes(scopes, offered: session.offeredWake, pushOn: session.push.isOn)
            Section {
                ForEach(NotifyScope.allCases) { scope in
                    let checked = scopes.contains(scope)
                    Toggle(isOn: Binding(get: { checked }, set: { on in
                        settings.set(scope, on, for: account)
                        Task { await store.syncPush(session) }
                    })) {
                        Text(scope.title)
                        if let note = notes[scope] { Text(note) }
                    }
                    .disabled(checked && scopes.count == 1)
                }
            } header: {
                Text(header.map { "Notify Me About on \($0)" } ?? "Notify Me About").formHeader()
            } footer: {
                Text("Whether Ladle is open or closed. At least one stays on; the switch above turns notifications off. \(closedWords(scopes))").formFooter()
            }
            .listRowBackground(Palette.raised)
        }
    }

    /// Whether this server alerts while Ladle is closed, as the rest of apron-web's `notificationsNote`.
    private func closedWords(_ scopes: [NotifyScope]) -> String {
        let settings = store.alerts.settings
        switch session.pushBlocker(inBuild: store.pushInBuild, relay: settings.relay, endpoint: settings.endpoint) {
        case .notInThisBuild: return "Alerts while Ladle is closed need push, which this build doesn't have yet."
        case .serverOffersNone: return "This server can't alert you while Ladle is closed."
        case .signIn: return "Sign in to be alerted while Ladle is closed."
        case .noRelay: return "Set a push relay below to be alerted while Ladle is closed."
        case .noDeviceToken: return "Waiting for iOS to register this device for push."
        case nil: break
        }
        switch session.push {
        case .off: return store.alerts.isOn ? "Not registered for push yet." : ""
        case .registering: return "Registering for push…"
        case .refused(let words): return "Push: \(words)"
        case .on(_, let wake): return wake?.isEmpty == true ? "None of your choices alert while Ladle is closed." : "Alerts even when Ladle is closed."
        }
    }
}

/// The relay this device's pushes go through (§4.9.2, docs/PUSH.md), only in a build with push.
private struct RelaySection: View {
    let store: SessionStore
    @State private var draft = ""
    @State private var refused = false

    var body: some View {
        let settings = store.alerts.settings
        Section {
            TextField("https://relay.example", text: $draft)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(save)
            if refused { Text("Enter an https address.").apText(.sm).foregroundStyle(Palette.danger) }
        } header: {
            Text("Push Relay").formHeader()
        } footer: {
            Text("Each server posts alerts for this device to this relay, which hands them to Apple. It sees who wrote, where, and the start of each message. Leave it empty to alert only while Ladle is open.").formFooter()
        }
        .listRowBackground(Palette.raised)
        .onAppear { draft = settings.relay?.absoluteString ?? "" }
    }

    private func save() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        let url = text.isEmpty ? nil : URL(string: text)
        refused = !text.isEmpty && url?.scheme != "https"
        guard !refused else { return }
        store.alerts.settings.setRelay(url)
        Task { await store.syncPush() }
    }
}
