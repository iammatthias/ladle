import ApronKit
import XCTest

final class ApronLinkTests: XCTestCase {
    private let chat = URL(string: "wss://chat.example/ws")!

    func testReadsTheSpecExamples() {
        XCTAssertEqual(ApronLink("https://link.apron.chat/#server=wss://chat.example/ws"), ApronLink(server: chat))
        XCTAssertEqual(ApronLink("https://link.apron.chat/#server=wss://chat.example/ws&room=general"), ApronLink(server: chat, room: "general"))
        XCTAssertEqual(ApronLink("https://link.apron.chat/#server=wss://chat.example/ws&room=t-123"), ApronLink(server: chat, room: "t-123"))
        XCTAssertEqual(ApronLink("https://link.apron.chat/#server=wss://chat.example/ws&room=general&message=1724803200042"),
                       ApronLink(server: chat, room: "general", message: LogID("1724803200042")))
        XCTAssertEqual(ApronLink("apron:?server=wss://chat.example/ws&room=general&message=1724803200042"),
                       ApronLink(server: chat, room: "general", message: LogID("1724803200042")))
        XCTAssertEqual(ApronLink("https://link.apron.chat/#server=wss://chat.example/ws&room=general&user=ada"),
                       ApronLink(server: chat, room: "general", user: "ada"))
        XCTAssertEqual(ApronLink("https://link.apron.chat/#server=ws://localhost:8080/ws&room=agent"),
                       ApronLink(server: URL(string: "ws://localhost:8080/ws"), room: "agent"))
        XCTAssertEqual(ApronLink("apron:?room=ops&message=1724803200042"), ApronLink(room: "ops", message: LogID("1724803200042")))
        XCTAssertEqual(ApronLink("https://link.apron.chat/#server=wss://chat.example/ws&room=%23ops/alerts"), ApronLink(server: chat, room: "#ops/alerts"))
        XCTAssertNil(ApronLink("https://link.apron.chat/#server=webrtc:k2Fp9xQ&signal=wss://signal.example/s&room=general"),
                     "a reserved transport is not reachable")
    }

    func testReadsASignInLinkOnlyFromAWebFragment() {
        let signIn = ApronLink("https://link.apron.chat/#server=wss://chat.example/ws&token=Hk41x9&state=q8Rz")
        XCTAssertEqual(signIn?.server, chat)
        XCTAssertEqual(signIn?.token, "Hk41x9")
        XCTAssertEqual(signIn?.state, "q8Rz")
        let uri = ApronLink("apron:?server=wss://chat.example/ws&room=general&token=Hk41x9&state=q8Rz")
        XCTAssertEqual(uri?.room, "general")
        XCTAssertNil(uri?.token, "an apron: URI never carries a credential")
        XCTAssertNil(uri?.state)
        XCTAssertNil(ApronLink("https://link.apron.chat/#token=Hk41x9"), "a sign-in link names its server")
        XCTAssertNil(ApronLink("https://link.apron.chat/?token=Hk41x9#server=wss://chat.example/ws"), "a credential in the query refuses the link")
    }

    func testQueryKeysFollowTheFragmentKeys() {
        XCTAssertEqual(ApronLink("https://link.apron.chat/?room=random&message=7#server=wss://chat.example/ws&room=general"),
                       ApronLink(server: chat, room: "general", message: LogID("7")))
        XCTAssertEqual(ApronLink("https://link.apron.chat/?server=wss://chat.example/ws&room=general"), ApronLink(server: chat, room: "general"))
    }

    func testTakesTheFirstValueAndIgnoresUnknownKeys() {
        let link = ApronLink("apron:?server=wss://chat.example/ws&room=general&room=random&server=wss://evil.example/ws&theme=dark")
        XCTAssertEqual(link?.server, chat)
        XCTAssertEqual(link?.room, "general")
        XCTAssertEqual(link?.otherKeys, [ApronLink.Pair(key: "theme", value: "dark")])
    }

    func testFormDecodesAndRefusesBadValues() {
        XCTAssertEqual(ApronLink("apron:?room=a%2Bb")?.room, "a+b")
        XCTAssertNil(ApronLink("apron:?room=two+words"), "a bare + is a space, which a room_id cannot hold")
        XCTAssertNil(ApronLink("apron:?room="))
        XCTAssertNil(ApronLink("apron:?room=a%09b"))
        XCTAssertNil(ApronLink("apron:?room=%ZZ"))
        XCTAssertNil(ApronLink("apron:?room=general&user=%00"))
        XCTAssertNil(ApronLink("apron:?message=1724803200042"), "message requires room")
        for message in ["0", "01724803200042", "-1", "1.5", "9007199254740992", "x"] {
            XCTAssertNil(ApronLink("apron:?room=general&message=\(message)"), message)
        }
        XCTAssertEqual(ApronLink("apron:?room=general&message=9007199254740991")?.message, LogID("9007199254740991"))
        XCTAssertNil(ApronLink("apron:?"), "a link to nothing")
    }

    func testRefusesServersItCannotReach() {
        XCTAssertNil(ApronLink("apron:?server=ws://chat.example/ws"), "ws only on a loopback host")
        XCTAssertNil(ApronLink("apron:?server=https://chat.example/ws"))
        XCTAssertNil(ApronLink("apron:?server=wss://ada:pw@chat.example/ws"))
        XCTAssertNil(ApronLink("apron:?server=wss://chat.example/ws%23x"))
        XCTAssertEqual(ApronLink("apron:?server=ws://127.0.0.1:8080/ws")?.server, URL(string: "ws://127.0.0.1:8080/ws"))
        XCTAssertEqual(ApronLink("apron:?server=ws://agent.localhost/ws")?.server, URL(string: "ws://agent.localhost/ws"))
        XCTAssertEqual(ApronLink("apron:?server=ws://[::1]:8080/ws")?.server, URL(string: "ws://[::1]:8080/ws"))
    }

    func testIsNoLinkInOtherShapes() {
        for text in ["https://chat.example/#server=wss://chat.example/ws", "https://link.apron.chat/x#server=wss://chat.example/ws",
                     "http://link.apron.chat/#server=wss://chat.example/ws", "web+apron:?room=ops", "apron:room=ops", "general"] {
            XCTAssertNil(ApronLink(text), text)
        }
        XCTAssertEqual(ApronLink("APRON:?room=ops")?.room, "ops")
        XCTAssertEqual(ApronLink(URL(string: "apron:?room=ops")!)?.room, "ops")
    }

    func testWritesTheWebForm() {
        let message = ApronLink(server: chat, room: "general", message: LogID("1724803200042"))
        XCTAssertEqual(message.webURL?.absoluteString, "https://link.apron.chat/#server=wss://chat.example/ws&room=general&message=1724803200042")
        XCTAssertEqual(ApronLink(server: chat, room: "#ops/alerts").webURL?.absoluteString,
                       "https://link.apron.chat/#server=wss://chat.example/ws&room=%23ops/alerts")
        XCTAssertEqual(ApronLink(server: chat, room: "a+b&c=d%e f").webURL?.absoluteString,
                       "https://link.apron.chat/#server=wss://chat.example/ws&room=a%2Bb%26c%3Dd%25e%20f")
        XCTAssertNil(ApronLink(room: "ops").webURL, "a relative link has no web form")
        let signIn = ApronLink("https://link.apron.chat/#server=wss://chat.example/ws&token=Hk41x9&state=q8Rz")
        XCTAssertEqual(signIn?.webURL?.absoluteString, "https://link.apron.chat/#server=wss://chat.example/ws", "a client never writes a credential")
    }

    func testResolvesARelativeLinkAgainstTheSender() {
        let relative = ApronLink("apron:?room=ops&message=1724803200042&theme=dark")
        XCTAssertEqual(relative?.resolved(against: chat).webURL?.absoluteString,
                       "https://link.apron.chat/#server=wss://chat.example/ws&room=ops&message=1724803200042&theme=dark")
        let absolute = ApronLink("apron:?server=wss://other.example/ws&room=ops")
        XCTAssertEqual(absolute?.resolved(against: chat).server, URL(string: "wss://other.example/ws"), "an absolute link keeps its server")
    }
}
