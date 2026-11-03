import ApronKit
import SwiftUI

/// A link to a server with several saved accounts (`LinkRoute.chooseAccount`): which one takes
/// it. A place link lists the accounts that could show it; a sign-in link lists every account
/// there, with the warning that a link from someone else signs in to their account, and a new
/// account as one more choice, since the link does not say whose token it carries.
struct AccountChooser: View {
    let choice: AccountChoice
    let store: SessionStore
    let pick: (UUID) -> Void
    let newAccount: (TokenPayload) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(choice.accounts) { record in
                        Button { pick(record.id) } label: { row(record) }
                            .buttonStyle(.plain)
                            .touchTarget()
                            .accessibilityLabel(accountName(record) + ", " + (store.session(for: record.id)?.serverName ?? record.label))
                    }
                    if let payload = choice.newAccount {
                        Button { newAccount(payload) } label: {
                            Label(AccountChoice.newAccountLabel, systemImage: "person.crop.circle.badge.plus")
                                .apText(.body).foregroundStyle(Palette.accent)
                        }
                        .buttonStyle(.plain)
                        .touchTarget()
                    }
                } footer: {
                    if choice.token != nil { Text(SignInLinkPrompt.warning).formFooter() }
                }
                .listRowBackground(Palette.raised)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle(choice.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.chrome)
    }

    private func accountName(_ record: ServerRecord) -> String {
        store.session(for: record.id)?.accountName ?? record.accountLabel
    }

    private func row(_ record: ServerRecord) -> some View {
        let session = store.session(for: record.id)
        let name = accountName(record)
        return HStack(spacing: Tokens.Space.s3) {
            Avatar(name: name, userID: record.account?.userID ?? record.id.uuidString, size: .md, image: session?.accountAvatarURL)
            VStack(alignment: .leading, spacing: 1) {
                Text(TextDirection.isolated(name)).apText(.body, .medium).foregroundStyle(Palette.ink).lineLimit(1)
                Text(session.map { "\($0.serverName) · \(choice.host)" } ?? choice.host).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
