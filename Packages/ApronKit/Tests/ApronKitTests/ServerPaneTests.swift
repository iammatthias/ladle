import Foundation
import XCTest
@testable import ApronKit

@MainActor
final class ServerPaneTests: XCTestCase {
    func testThePaneSaysWhichServerHowItStandsAndWhoYouAre() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID)).pane
        XCTAssertEqual(home, ServerPane(name: "Home", host: "home.example", description: nil, connection: "Connected", tone: .ok,
                                        signedInAs: "Signed in as \u{2068}Sam\u{2069}", address: "wss://home.example/ws", protocolVersion: "Apron 10",
                                        versionWarning: nil))
        let demo = try XCTUnwrap(store.session(for: PreviewFixtures.demoID)).pane
        XCTAssertEqual(demo.name, "Apron Demo")
        XCTAssertEqual(demo.description, "The public demo of [Apron](https://github.com/shazow/apron), an open chat protocol.")
        XCTAssertEqual(demo.signedInAs, "Signed in as \u{2068}Guest 7\u{2069} (guest)")
    }

    func testAServerSpeakingAVersionLadleDoesNotReadIsWarnedAbout() throws {
        func info(_ apron: Int) throws -> ServerInfo { try XCTUnwrap(ServerInfo(params: ["apron": .number(String(apron)), "auth": ["guest"]])) }
        XCTAssertEqual(ServerInfo.version, 10)
        XCTAssertNil(try info(10).versionWarning)
        XCTAssertNil(try info(9).versionWarning, "v9 is read in full")
        XCTAssertEqual(try info(11).versionWarning,
                       "This server speaks Apron 11, newer than this version of Ladle knows (Apron 10). Some features may not work until Ladle is updated.")
        XCTAssertEqual(try info(8).versionWarning, "This server speaks Apron 8, older than Ladle reads (Apron 9 and 10). Some features may not work.")
    }

    func testAServerNotConnectedSaysSoInRed() {
        let session = ServerSession(record: ServerRecord(url: URL(string: "wss://chat.example/ws")!), tokens: InMemoryTokenStore())
        let pane = session.pane
        XCTAssertEqual(pane.connection, "Not connected")
        XCTAssertEqual(pane.tone, .danger)
        XCTAssertNil(pane.signedInAs)
        XCTAssertNil(pane.protocolVersion)
        XCTAssertEqual(pane.name, "chat.example")
    }
}
