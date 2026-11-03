import ApronKit
import SwiftUI

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
                case .history: HistoryPreferences(store: store)
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
func sessions(_ store: SessionStore, _ server: UUID?) -> [ServerSession] {
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

/// Media, as apron-web's: where media loads from, the viewer's trusted and blocked sites (on
/// every server), and, read-only, the sites each server trusts for its own media.
private struct MediaPreferences: View {
    let store: SessionStore

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
                Text("Load Media From").formHeader()
            } footer: {
                Text("Loading an image, a video or an avatar tells the site that hosts it that you are reading. Under This Server and Trusted Sites, media from anywhere else waits for a tap, and avatars and custom emoji from elsewhere don't show.").formFooter()
            }

            SiteListSection(title: "Trusted Sites", sites: settings.origins, prompt: "Add a site, such as cdn.example",
                            refusal: "Enter an https site or address, such as cdn.example or https://cdn.example/a.png.",
                            footer: "Your trusted sites apply on every server. Always Load on a waiting image adds its site here. Under Any Site they stay listed for when you switch back.",
                            parse: MediaSettings.parseOrigins, add: { settings.add($0) }, remove: settings.remove)

            SiteListSection(title: "Blocked Sites", sites: settings.blocked, prompt: "Block a site, such as ads.example",
                            refusal: "Enter a site or address, such as ads.example or https://ads.example/a.png.",
                            footer: "Media from a blocked site, or from a site under it such as a.ads.example, never shows on any server, even from a trusted site or under Any Site. Block on a waiting image adds its site here.",
                            parse: MediaSettings.parseBlockedOrigins, add: { settings.addBlocked($0) }, remove: settings.unblock)

            let named = serverSites
            if !named.isEmpty {
                Section {
                    ForEach(named, id: \.name) { server in
                        LabeledContent(server.name, value: server.sites.joined(separator: ", "))
                    }
                } header: {
                    Text("Trusted by Your Servers").formHeader()
                } footer: {
                    Text("Each server's own address and the sites it names for its media load on that server only.").formFooter()
                }
            }
        }
        .navigationTitle("Media")
        .navigationBarTitleDisplayMode(.inline)
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

/// A list of sites by host, each removed with Delete, and a field that adds what it names: Media's
/// Trusted Sites and Blocked Sites. Text in which `parse` finds no site shows `refusal`.
private struct SiteListSection: View {
    let title: String
    let sites: [String]
    let prompt: String
    let refusal: String
    let footer: String
    let parse: (String) -> [String]
    let add: (String) -> Void
    let remove: (String) -> Void
    @State private var draft = ""
    @State private var refused = false

    var body: some View {
        Section {
            ForEach(sites, id: \.self) { site in
                Text(MediaPreferences.host(site)).apText(.body).foregroundStyle(Palette.ink)
                    .accessibilityHint("Swipe up or down for Delete")
            }
            .onDelete { offsets in
                for site in offsets.map({ sites[$0] }) { remove(site) }
            }
            HStack {
                TextField(prompt, text: $draft)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(submit)
                    .onChange(of: draft) { refused = false }
                Button("Add", action: submit).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if refused {
                Text(refusal).apText(.sm).foregroundStyle(Palette.danger)
            }
        } header: {
            Text(title).formHeader()
        } footer: {
            Text(footer).formFooter()
        }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !parse(text).isEmpty else {
            refused = true
            return
        }
        add(text)
        draft = ""
    }
}

/// History, as apron-web's (#137): how long messages are kept on this device, how much that
/// takes, and why keeping stopped.
private struct HistoryPreferences: View {
    let store: SessionStore

    var body: some View {
        let settings = store.historySettings
        Form {
            Section {
                Picker("Retention", selection: Binding(get: { settings.retention }, set: { retention in Task { await store.setRetention(retention) } })) {
                    ForEach(HistoryRetention.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if let failure = settings.failure {
                    Text(failure).apText(.sm).foregroundStyle(Palette.danger)
                }
                if settings.retention != .off { clearButtons(settings) }
            } footer: {
                Text(settings.retention == .off
                     ? "How long this device keeps messages it has loaded. Ladle still keeps the last day of each room, up to 150 messages, so it opens at once."
                     : "How long this device keeps messages it has loaded. Each account’s stays when you sign out.").formFooter()
            }
            .listRowBackground(Palette.raised)
            Section {
                Toggle("Include Private Rooms", isOn: $includePrivate)
                ForEach(signedIn, id: \.record.id) { session in
                    Button(signedIn.count == 1 ? "Export Chats" : "Export \(session.serverName)") { export(session) }
                }
                if let exportNote { Text(exportNote).apText(.sm).foregroundStyle(Palette.inkMuted) }
            } header: {
                Text("Export Chats").formHeader()
            } footer: {
                Text(signedIn.isEmpty ? "Sign in to a server to export what Ladle has loaded and kept of it."
                     : "Saves what Ladle has loaded and kept of a server as a .jsonl file, to share or keep. Private rooms go only when included.").formFooter()
            }
            .listRowBackground(Palette.raised)
            Section {
                Button("Open an Export…") { importing = true }
            } footer: {
                Text("Reads a .jsonl file saved here or from apron-web, read-only, without signing in to its server.").formFooter()
            }
            .listRowBackground(Palette.raised)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.chrome)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(clearing == .all ? "Delete the history this device keeps for every account?" : "Delete the history this device keeps for this account?",
                            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), titleVisibility: .visible,
                            presenting: clearing) { which in
            Button("Delete", role: .destructive) {
                switch which {
                case .current(let server): store.session(for: server)?.clearKept()
                case .all: store.clearAllKept()
                }
            }
        } message: { _ in
            Text("This cannot be undone.")
        }
        .sheet(item: $sharing) { ShareSheet(items: [$0.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.jsonLines, .json, .plainText, .data]) { result in
            if case .success(let url) = result { reading = OpenedExport(url: url) }
        }
        .fullScreenCover(item: $reading) { ArchiveViewer(opened: $0, mediaSettings: store.mediaSettings) }
    }

    /// History's Clear buttons, as apron-web's (#199): the signed-in account's (one per server
    /// when several are signed in), and every account's.
    @ViewBuilder private func clearButtons(_ settings: HistorySettings) -> some View {
        let current = signedIn.filter { session in session.keptAccount.map { settings.keptBytes[$0] != nil } ?? false }
        let labels = HistorySettings.clearLabels(accounts: settings.keptBytes.count, current: !current.isEmpty, used: settings.used)
        if let label = labels.current {
            ForEach(current, id: \.record.id) { session in
                Button(current.count == 1 ? label : "Clear \(session.serverName)") { clearing = .current(server: session.record.id) }
                    .foregroundStyle(Palette.danger)
            }
        }
        if let label = labels.all {
            Button(label) { clearing = .all }.foregroundStyle(Palette.danger)
        }
    }

    private enum Clearing: Hashable {
        case current(server: UUID)
        case all
    }

    @State private var clearing: Clearing?

    /// apron-web's "Include private rooms", off until asked (#171), for this visit to History.
    @State private var includePrivate = false
    @State private var exportNote: String?
    @State private var sharing: SharedFile?
    @State private var importing = false
    @State private var reading: OpenedExport?

    private var signedIn: [ServerSession] {
        store.records.compactMap { store.session(for: $0.id) }.filter { $0.you != nil }
    }

    /// Writes the export into `Exports` in the temporary directory, which `LadleApp` clears at
    /// launch, and offers it through the share sheet.
    private func export(_ session: ServerSession) {
        let export = session.exportArchive(includingPrivate: includePrivate)
        let folder = FileManager.default.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
        let url = folder.appending(path: export.name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(export.text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            exportNote = export.messages == 0 && export.rooms == 0 ? "Nothing is loaded to export yet." : export.words
            sharing = SharedFile(url: url)
        } catch {
            exportNote = "The export couldn’t be saved. Try again."
        }
    }
}

/// A file to hand to the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet, for a file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
