import ApronKit
import SwiftUI

/// Adds a server, or edits one. The origin follows the address while it is still the address's
/// default; a token works only from the origin that obtained it, so the user may change it.
struct ServerEditorView: View {
    let record: ServerRecord?
    let onSave: (ServerRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var label = ""
    @State private var origin = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("wss://chat.example/ws", text: $address)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: address) { old, new in
                            let previousDefault = Self.url(from: old).map(ServerRecord.defaultOrigin(for:)) ?? ""
                            guard origin.isEmpty || origin == previousDefault else { return }
                            origin = Self.url(from: new).map(ServerRecord.defaultOrigin(for:)) ?? ""
                        }
                    TextField("Name", text: $label, prompt: Text(url.map(ServerRecord.defaultLabel(for:)) ?? "Name"))
                } header: {
                    Text("Server")
                } footer: {
                    if !address.isEmpty, url == nil { Text("Enter a ws:// or wss:// address.") }
                }
                Section {
                    TextField("https://web.example", text: $origin)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Origin")
                } footer: {
                    Text("Sent as the Origin header. A token signs in only from the origin of the client that obtained it, such as https://web.apron.chat.")
                }
            }
            .navigationTitle(record == nil ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(url == nil)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var url: URL? { Self.url(from: address) }

    private static func url(from address: String) -> URL? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil
        else { return nil }
        return url
    }

    private func load() {
        guard let record else { return }
        address = record.url.absoluteString
        label = record.label
        origin = record.origin
    }

    private func save() {
        guard let url else { return }
        let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
        let trimmedOrigin = origin.trimmingCharacters(in: .whitespaces)
        var saved = record ?? ServerRecord(url: url)
        saved.url = url
        saved.label = trimmedLabel.isEmpty ? ServerRecord.defaultLabel(for: url) : trimmedLabel
        saved.origin = trimmedOrigin.isEmpty ? ServerRecord.defaultOrigin(for: url) : trimmedOrigin
        onSave(saved)
        dismiss()
    }
}
