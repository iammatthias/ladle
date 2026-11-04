import ApronKit
import SwiftUI

/// A sign-in link of no proposal here, for a saved server: someone else may have made it, so
/// it waits for the user (§4.11.2, link.apron.chat SPEC §2.1).
struct AskedLink: Identifiable {
    let id = UUID()
    let session: ServerSession
    let token: String

    @MainActor
    var prompt: SignInLinkPrompt {
        SignInLinkPrompt(host: session.record.url.host() ?? session.serverName, addAs: session.linkAddAs,
                         keptSession: session.you == nil && session.record.account != nil)
    }
}

extension View {
    /// apron-web's "Sign in with this link?" dialog: which server, what it replaces, the warning
    /// that a link from someone else signs in to their account, and, where an account is signed
    /// in on that server, Add It beside Sign In, since a link doesn't say which it is for.
    /// A link asked about while another is being used shows once that one ends (`LinkWork`).
    func signInLinkDialog(_ asked: Binding<AskedLink?>, outcome: Binding<String?>, links: LinkWork) -> some View {
        confirmationDialog(asked.wrappedValue?.prompt.title ?? "", isPresented: Binding { asked.wrappedValue != nil && !links.isBusy } set: { if !$0 { asked.wrappedValue = nil } },
                           titleVisibility: .visible, presenting: asked.wrappedValue) { link in
            let prompt = link.prompt
            if prompt.adds {
                Button("Add It") {
                    asked.wrappedValue = nil
                    links.run {
                        do {
                            try await link.session.approveAddition(link: link.token, proposal: nil)
                            outcome.wrappedValue = "Added · sign in with it anywhere"
                        } catch {
                            outcome.wrappedValue = additionErrorText(error, scheme: "link")
                        }
                    }
                }
            }
            Button("Sign In", role: prompt.adds || link.session.you != nil ? .destructive : nil) {
                asked.wrappedValue = nil
                links.run {
                    do {
                        try await link.session.signIn(link: link.token, proposal: nil)
                    } catch {
                        outcome.wrappedValue = SignInLinkPrompt.failure(errorText(error))
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { link in
            Text(link.prompt.lines.joined(separator: "\n\n"))
        }
    }
}
