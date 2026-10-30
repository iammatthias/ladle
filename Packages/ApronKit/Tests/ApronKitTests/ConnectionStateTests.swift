import XCTest
@testable import ApronKit

@MainActor
final class ConnectionStateTests: XCTestCase {
    private let record = ServerRecord(url: URL(string: "wss://chat.example/ws")!, label: "Chat")

    private func shown(_ status: ServerSession.Status) -> String {
        guard let state = ConnectionState(status) else { return "live" }
        return [state.symbol, state.title(record), state.detail ?? "-", state.isProblem ? "problem" : "ok", state.canRetry ? "retry" : "no retry"].joined(separator: " | ")
    }

    func testEachStatusInWords() {
        XCTAssertEqual(shown(.signedIn), "live")
        XCTAssertEqual(shown(.connecting), "arrow.triangle.2.circlepath | Connecting… | - | ok | no retry")
        XCTAssertEqual(shown(.signingIn), "arrow.triangle.2.circlepath | Connecting… | - | ok | no retry")
        XCTAssertEqual(shown(.reconnecting(attempt: 3, delay: .seconds(4))), "arrow.triangle.2.circlepath | Reconnecting… | - | ok | no retry")
        XCTAssertEqual(shown(.reconnecting(attempt: 4, delay: .milliseconds(7500))),
                       "wifi.exclamationmark | Can't reach chat.example. Retrying in 8 s | - | problem | retry")
        XCTAssertEqual(shown(.offline), "wifi.slash | Not connected | - | problem | retry")
        XCTAssertEqual(shown(.signedOut), "person.crop.circle.badge.exclamationmark | Signed out of Chat | Sign in from the room list to send. | problem | no retry")
        XCTAssertEqual(shown(.stopped(.signedOut)), shown(.signedOut))
        XCTAssertEqual(shown(.stopped(.denied("Banned for spam"))), "hand.raised | chat.example refused the connection | Banned for spam | problem | retry")
        XCTAssertEqual(shown(.stopped(.rejected(status: 403))),
                       "hand.raised | chat.example refused this app's origin (HTTP 403) | Edit the server's origin to match the client that made your token. | problem | no retry")
    }
}
