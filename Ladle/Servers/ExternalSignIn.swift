import ApronKit
import AuthenticationServices
import SwiftUI

/// A server's own sign-in page (§4.11.5) in `ASWebAuthenticationSession`, through SwiftUI's
/// `WebAuthenticationSession`. Where the page returns to this app (`returns`), the session
/// catches the redirect to the record's origin, which it can only where that host is one of the
/// app's associated domains, and hands back the link's token and `state`. Otherwise the page
/// shows a code: the session stays open until the user closes it, and the code goes in the form.
@MainActor
enum ExternalSignIn {
    enum Ending {
        /// The page came back with a link for this device's proposal.
        case link(token: String, proposal: Proposal)
        /// The page came back with a link whose `state` is not this device's.
        case foreignLink
        /// Closed, or a page that shows a code: the form takes it.
        case closed
    }

    static func open(_ page: URL, returns: Bool, origin: String, proposals: Proposals,
                     session: WebAuthenticationSession) async throws -> Ending {
        let back = returns ? SignInPage.returnURL(origin: origin, domains: .app) : nil
        let callback: ASWebAuthenticationSession.Callback = back.flatMap { url in url.host().map { .https(host: $0, path: "/") } }
            ?? .customScheme("ladle-signin")
        let returned: URL
        do {
            returned = try await session.authenticate(using: page, callback: callback, additionalHeaderFields: [:])
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return .closed
        }
        guard let link = SignInFragment(returned) else { return .closed }
        guard let proposal = proposals.find(link.state, now: Date()) else { return .foreignLink }
        return .link(token: link.token, proposal: proposal)
    }

    /// What the form says when the page came back with someone else's link.
    static let foreignWords = "The sign-in page came back with a link this device didn’t ask for, so Ladle didn’t use it. Start again."
}
