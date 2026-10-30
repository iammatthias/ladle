import Foundation


/// The session's state as UX spec 4.1 shows it. Nil when live.
public struct ConnectionState {
    public let symbol: String
    public let isProblem: Bool
    public let canRetry: Bool
    public var detail: String?
    private let words: (ServerRecord) -> String

    public init?(_ status: ServerSession.Status) {
        switch status {
        case .signedIn:
            return nil
        case .connecting, .signingIn:
            (symbol, isProblem, canRetry, words) = ("arrow.triangle.2.circlepath", false, false, { _ in "Connecting…" })
        case .reconnecting(let attempt, _) where attempt <= 3:
            (symbol, isProblem, canRetry, words) = ("arrow.triangle.2.circlepath", false, false, { _ in "Reconnecting…" })
        case .reconnecting(_, let delay):
            let seconds = Int(delay.components.seconds) + 1
            (symbol, isProblem, canRetry, words) = ("wifi.exclamationmark", true, true, { "Can't reach \($0.url.host() ?? $0.label). Retrying in \(seconds) s" })
        case .offline:
            (symbol, isProblem, canRetry, words) = ("wifi.slash", true, true, { _ in "Not connected" })
        case .signedOut, .stopped(.signedOut):
            (symbol, isProblem, canRetry, words) = ("person.crop.circle.badge.exclamationmark", true, false, { "Signed out of \($0.label)" })
            detail = "Sign in from the room list to send."
        case .stopped(.denied(let message)):
            (symbol, isProblem, canRetry, words) = ("hand.raised", true, true, { "\($0.url.host() ?? $0.label) refused the connection" })
            detail = message
        case .stopped(.rejected(let code)):
            (symbol, isProblem, canRetry, words) = ("hand.raised", true, false, { "\($0.url.host() ?? $0.label) refused this app's origin (HTTP \(code))" })
            detail = "Edit the server's origin to match the client that made your token."
        }
    }

    public func title(_ record: ServerRecord) -> String { words(record) }
}
