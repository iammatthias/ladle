import ApronKit
import SwiftUI

/// Preferences, as the web's Media preferences: where media loads from, the viewer's trusted
/// sites (on every server), and, read-only, the sites each server trusts for its own media.
struct PreferencesView: View {
    let store: SessionStore
    @State private var draft = ""
    @State private var refused = false
    /// Appearance's custom CSS as edited, until Preferences closes.
    @State private var editor: ThemeEditor
    @Environment(\.dismiss) private var dismiss

    init(store: SessionStore) {
        self.store = store
        _editor = State(initialValue: ThemeEditor(settings: store.appearance))
    }

    var body: some View {
        let settings = store.mediaSettings
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Appearance") { AppearanceView(editor: editor) }
                }

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
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        // Closing Preferences, not moving between its screens, drops edits not applied.
        .onDisappear { editor.close() }
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
