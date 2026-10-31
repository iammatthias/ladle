import ApronKit
import SwiftUI
import UserNotifications

/// Preferences, as apron-web's (#184): Profile, Notifications, Appearance, Media and History, in
/// its order, each a screen of its own. It opens at a section when asked (`openPreferences`), as
/// apron-web's `preferencesOpener`, and Back steps through the sections opened, as the web's
/// address does. Profile and Notifications are per server: opened for one server, they show it;
/// opened from the server list, they list the servers signed in.
struct PreferencesView: View {
    let store: SessionStore
    /// The server Preferences was opened for, from its profile bar.
    let server: UUID?
    @State private var path: [PreferencesSection]
    /// Appearance's custom CSS as edited, until Preferences closes.
    @State private var editor: ThemeEditor
    @Environment(\.dismiss) private var dismiss

    init(store: SessionStore, request: PreferencesRequest = PreferencesRequest()) {
        self.store = store
        server = request.server
        _path = State(initialValue: request.section.map { [$0] } ?? [])
        _editor = State(initialValue: ThemeEditor(settings: store.appearance))
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(PreferencesSection.allCases) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.symbol).apText(.body).foregroundStyle(Palette.ink)
                }
                .listRowBackground(Palette.raised)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(for: PreferencesSection.self) { section in
                switch section {
                case .profile: ProfilePreferences(store: store, server: server)
                case .notifications: NotificationsPreferences(store: store, server: server)
                case .appearance: AppearanceView(editor: editor)
                case .media: MediaPreferences(store: store)
                case .history: HistoryPreferences()
                }
            }
        }
        // Closing Preferences, not moving between its screens, drops edits not applied.
        .onDisappear { editor.close() }
    }
}

/// What opens Preferences, and where.
struct PreferencesRequest: Identifiable {
    let id = UUID()
    var section: PreferencesSection?
    var server: UUID?
}

/// Opens Preferences, at a section and for a server when given; a struct, as `OpenRoomAction`.
struct OpenPreferencesAction {
    let open: (PreferencesRequest) -> Void
    init(_ open: @escaping (PreferencesRequest) -> Void) { self.open = open }
    func callAsFunction(_ section: PreferencesSection? = nil, server: UUID? = nil) {
        open(PreferencesRequest(section: section, server: server))
    }
}

extension EnvironmentValues {
    /// Opens Preferences, as apron-web's `preferencesOpener.open(section)`.
    @Entry var openPreferences = OpenPreferencesAction { _ in }
}

/// The servers a per-server section shows: the one asked for, else every server signed in.
@MainActor
private func sessions(_ store: SessionStore, _ server: UUID?) -> [ServerSession] {
    store.records.filter { server == nil || $0.id == server }.compactMap { store.session(for: $0.id) }.filter { $0.you != nil }
}

/// Profile, as apron-web's: your status and profile on one server (`YouView`). Opened from the
/// server list, it lists the servers you are signed in to.
private struct ProfilePreferences: View {
    let store: SessionStore
    let server: UUID?

    var body: some View {
        let signedIn = sessions(store, server)
        if signedIn.count == 1, let session = signedIn.first {
            YouView(session: session, standalone: false)
        } else {
            List {
                if signedIn.isEmpty {
                    Text("Sign in to a server to set your name, avatar, bio and status there.")
                        .apText(.ui).foregroundStyle(Palette.inkMuted)
                }
                ForEach(signedIn, id: \.record.id) { session in
                    NavigationLink {
                        YouView(session: session, standalone: false)
                    } label: {
                        LabeledContent(session.serverName, value: session.you.map(session.displayName(for:)) ?? "")
                    }
                }
                .listRowBackground(Palette.raised)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Notifications, as apron-web's, as far as Ladle notifies: whether iOS lets Ladle notify (Remind
/// Me's reminders), and Pause notifications on each server that offers it.
private struct NotificationsPreferences: View {
    let store: SessionStore
    let server: UUID?
    @State private var authorization: UNAuthorizationStatus?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section {
                LabeledContent("Notifications", value: words)
                if authorization == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(settings) }
                }
            } footer: {
                Text("Ladle notifies you of the reminders you set with Remind Me. Alerts for messages and mentions while it is closed need push (§4.9), which Ladle doesn't have yet.")
            }
            .listRowBackground(Palette.raised)
            ForEach(sessions(store, server).filter(\.mayMute), id: \.record.id) { session in
                PauseSection(session: session, header: server == nil ? session.serverName : nil)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.chrome)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
    }

    private var words: String {
        switch authorization {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off in Settings"
        case .notDetermined: "Asked with your first reminder"
        default: ""
        }
    }
}

/// Media, as apron-web's: where media loads from, the viewer's trusted sites (on every server),
/// and, read-only, the sites each server trusts for its own media.
private struct MediaPreferences: View {
    let store: SessionStore
    @State private var draft = ""
    @State private var refused = false

    var body: some View {
        let settings = store.mediaSettings
        Form {
            Section {
                Picker("Load Media From", selection: Binding(get: { settings.policy }, set: { settings.update(policy: $0) })) {
                    Text("This Server and Trusted Sites").tag(MediaPolicy.trusted)
                    Text("Any Site").tag(MediaPolicy.any)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Load Media From")
            } footer: {
                Text("Loading an image, a video or an avatar tells the site that hosts it that you are reading. Under This Server and Trusted Sites, media from anywhere else waits for a tap, and avatars and custom emoji from elsewhere don't show.")
            }

            Section {
                ForEach(settings.origins, id: \.self) { origin in
                    Text(Self.host(origin)).apText(.body).foregroundStyle(Palette.ink)
                        .accessibilityHint("Swipe up or down for Delete")
                }
                .onDelete { offsets in
                    for origin in offsets.map({ settings.origins[$0] }) { settings.remove(origin) }
                }
                HStack {
                    TextField("Add a site, such as cdn.example", text: $draft)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(add)
                        .onChange(of: draft) { refused = false }
                    Button("Add", action: add).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if refused {
                    Text("Enter an https site or address, such as cdn.example or https://cdn.example/a.png.")
                        .apText(.sm).foregroundStyle(Palette.danger)
                }
            } header: {
                Text("Trusted Sites")
            } footer: {
                Text("Your trusted sites apply on every server. Always Load on a waiting image adds its site here. Under Any Site they stay listed for when you switch back.")
            }

            let named = serverSites
            if !named.isEmpty {
                Section {
                    ForEach(named, id: \.name) { server in
                        LabeledContent(server.name, value: server.sites.joined(separator: ", "))
                    }
                } header: {
                    Text("Trusted by Your Servers")
                } footer: {
                    Text("Each server's own address and the sites it names for its media load on that server only.")
                }
            }
        }
        .navigationTitle("Media")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if MediaSettings.parseOrigins(text).isEmpty {
            refused = true
            return
        }
        store.mediaSettings.add(text)
        draft = ""
    }

    /// Each signed-in server's own origin and the ones `ext:media` names, by host.
    private var serverSites: [(name: String, sites: [String])] {
        store.records.compactMap { record in
            guard let session = store.session(for: record.id), session.server != nil else { return nil }
            let gate = session.mediaGate
            let sites = ([gate.origin].compactMap { $0 } + gate.serverOrigins.sorted()).map(Self.host)
            return (session.serverName, sites)
        }
    }

    static func host(_ origin: String) -> String {
        origin.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }
}

/// History, as apron-web's, as far as Ladle keeps any: it keeps no messages on this device, so
/// there is no retention to choose, and export is not built yet.
private struct HistoryPreferences: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Messages Kept", value: "None")
            } footer: {
                Text("Ladle keeps no messages on this device: each room loads from its server when you open it. It keeps how far you have read, your drafts and your reminders, until you remove the server.")
            }
            .listRowBackground(Palette.raised)
            Section {
                LabeledContent("Export Chats", value: "Not yet")
                LabeledContent("Open an Export", value: "Not yet")
            } footer: {
                Text("apron-web saves what it has loaded as a .jsonl file and reads one back. Ladle doesn't yet.")
            }
            .listRowBackground(Palette.raised)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.chrome)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }
}
