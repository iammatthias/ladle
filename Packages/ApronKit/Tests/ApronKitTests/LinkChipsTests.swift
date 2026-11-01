import XCTest
@testable import ApronKit

@MainActor
final class LinkChipsTests: XCTestCase {
    private let releaseThread = "1793092125000"

    private func home() async throws -> ServerSession {
        let store = await PreviewFixtures.makeStore()
        return try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
    }

    /// What each chip in a body shows, a part at a time: `[label]`, `(detail)`, `@mention`.
    private func shown(_ text: String, format: String = "plain", in session: ServerSession) -> [String] {
        let out = MessageText.attributed(["text": .string(text), "format": .string(format)], links: session.linkChip, you: "sam")
        return out.runs.compactMap { run in
            let words = String(out[run.range].characters).replacingOccurrences(of: "\u{2068}", with: "").replacingOccurrences(of: "\u{2069}", with: "")
            if let part = run[LinkChipKey.self] { return part.isDetail ? "(\(words))" : "[\(words)]" }
            if let mention = run[MentionKey.self] { return "\(words) \(mention.userID) \(mention.isYou)" }
            return nil
        }
    }

    func testEachKindOfPlaceSaysWhatItIs() async throws {
        let session = try await home()
        func chip(_ link: String) -> LinkChip? { session.linkChip(URL(string: link)!) }
        XCTAssertEqual(chip("apron:?room=general&message=1793091780000"),
                       LinkChip(kind: .message, label: "Message", detail: " in #\u{2068}general\u{2069}"))
        XCTAssertEqual(chip("https://link.apron.chat/#server=wss://home.example/ws&room=design"),
                       LinkChip(kind: .room, label: "\u{2068}design\u{2069}"))
        XCTAssertEqual(chip("apron:?room=\(releaseThread)"),
                       LinkChip(kind: .thread, label: "\u{2068}Release 0.2\u{2069}", detail: " in #\u{2068}general\u{2069}"))
        XCTAssertEqual(chip("apron:?room=design&user=ada"), LinkChip(kind: .user("ada"), label: "@\u{2068}Ada Okafor\u{2069}"))
        XCTAssertEqual(chip("apron:?room=r-8f2a&message=3"), LinkChip(kind: .message, label: "Message", detail: " in #\u{2068}r-8f2a\u{2069}"),
                       "a room not known here is its room_id")
        XCTAssertEqual(chip("apron:?room=r-8f2a")?.label, "\u{2068}r-8f2a\u{2069}")
    }

    func testAnotherServersPlaceIsItsHostAndWhatItIs() async throws {
        let session = try await home()
        func chip(_ link: String) -> LinkChip? { session.linkChip(URL(string: link)!) }
        let message = try XCTUnwrap(chip("https://link.apron.chat/#server=wss://demo.apron.example/ws&room=lobby&message=12"))
        XCTAssertEqual(message, LinkChip(kind: .elsewhere, label: "demo.apron.example", detail: " · Message"))
        XCTAssertEqual(message.spoken, "Message on demo.apron.example, another server")
        XCTAssertEqual(chip("apron:?server=wss://chat.example:8443/&room=general"), LinkChip(kind: .elsewhere, label: "chat.example:8443", detail: " · Room"),
                       "nothing looked up, even a room this server has")
        XCTAssertEqual(chip("apron:?server=wss://home.example/other&room=general")?.label, "home.example", "another endpoint on the same host")
    }

    func testALinkThatIsNotAPlaceStaysALink() async throws {
        let session = try await home()
        for link in ["apron:?room=general&user=zed", "apron:?server=wss://demo.apron.example/ws&room=lobby&user=ada",
                     "https://link.apron.chat/#server=wss://home.example/ws&token=t1&room=general", "apron:?server=wss://home.example/ws",
                     "apron:?user=ada", "apron:?room=general&preferences=media", "https://example.com/"] {
            XCTAssertNil(session.linkChip(URL(string: link)!), link)
        }
    }

    func testOnlyALinkWrittenAsItsOwnURLBecomesAChip() async throws {
        let session = try await home()
        XCTAssertEqual(shown("see apron:?room=general&message=1793091780000.", in: session), ["[Message]", "( in #general)"])
        XCTAssertEqual(shown("see <apron:?room=general&message=1793091780000>", format: "markdown", in: session), ["[Message]", "( in #general)"])
        XCTAssertEqual(shown("[that one](apron:?room=general&message=1793091780000)", format: "markdown", in: session), [])
        XCTAssertEqual(shown("`apron:?room=general`", format: "markdown", in: session), [])
        XCTAssertEqual(shown("<https://link.apron.chat/#room=général>", format: "markdown", in: session), ["[général]"],
                       "an autolink Markdown percent-encodes is still its own URL")
        XCTAssertEqual(shown("apron:?room=design&user=sam and https://link.apron.chat/#server=wss://demo.apron.example/ws&room=lobby", in: session),
                       ["@Sam sam true", "[demo.apron.example]", "( · Room)"])
    }

    func testTheChipKeepsTheLinkAsWritten() async throws {
        let session = try await home()
        let out = MessageText.attributed(["text": "apron:?room=design", "format": "plain"], links: session.linkChip)
        XCTAssertEqual(out.runs.compactMap(\.link).map(\.absoluteString), ["apron:?room=design"])
    }
}
