import Foundation


/// The session's state as UX spec 4.1 shows it. Nil when live.
public struct ConnectionState {
    public let symbol: String
    public let isProblem: Bool
    public let canRetry: Bool
    public var detail: String?
    private let words: (ServerRecord, Date) -> String

    /// `until` is when a reconnect's wait ends (`ServerSession.reconnectAt`), which the words count
    /// down to, as apron-web's banner (#223); without it they say the wait as it began.
    public init?(_ status: ServerSession.Status, until: Date? = nil) {
        switch status {
        case .signedIn:
            return nil
        case .connecting, .signingIn:
            (symbol, isProblem, canRetry, words) = ("arrow.triangle.2.circlepath", false, false, { _, _ in "Connecting…" })
        case .reconnecting(let attempt, _) where attempt <= 3:
            (symbol, isProblem, canRetry, words) = ("arrow.triangle.2.circlepath", false, false, { _, _ in "Reconnecting…" })
        case .reconnecting(_, let delay):
            let began = Int(delay.components.seconds) + 1
            (symbol, isProblem, canRetry, words) = ("wifi.exclamationmark", true, true, { record, now in
                let seconds = until.map { max(1, Int($0.timeIntervalSince(now).rounded(.up))) } ?? began
                return "Can't reach \(record.url.host() ?? record.label). Retrying in \(seconds) s"
            })
        case .offline:
            (symbol, isProblem, canRetry, words) = ("wifi.slash", true, true, { _, _ in "Not connected" })
        case .signedOut, .stopped(.signedOut):
            (symbol, isProblem, canRetry, words) = ("person.crop.circle.badge.exclamationmark", true, false, { record, _ in "Signed out of \(record.label)" })
            detail = "Sign in from the room list to send."
        case .stopped(.denied(let message)):
            (symbol, isProblem, canRetry, words) = ("hand.raised", true, true, { record, _ in "\(record.url.host() ?? record.label) refused the connection" })
            detail = message
        case .stopped(.rejected(let code)):
            (symbol, isProblem, canRetry, words) = ("hand.raised", true, false, { record, _ in "\(record.url.host() ?? record.label) refused this app's origin (HTTP \(code))" })
            detail = "Edit the server's origin to match the client that made your token."
        }
    }

    public func title(_ record: ServerRecord, now: Date = Date()) -> String { words(record, now) }
}
