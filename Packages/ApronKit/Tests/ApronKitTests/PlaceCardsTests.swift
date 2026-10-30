import XCTest
@testable import ApronKit

@MainActor
final class PlaceCardsTests: XCTestCase {
    private let home = URL(string: "wss://home.example/ws")!
    private let demo = URL(string: "wss://demo.apron.example/ws")!
    /// Message `n` of the fixtures: n minutes after 2026-10-27 09:00 UTC.
    private func id(_ minute: Int64) -> LogID { LogID(String(1_793_091_600_000 + minute * 60_000))! }
    private let releaseThread = "1793092125000"

    private func message(_ text: String, in roomID: String = "design", id: LogID = LogID("1")!) -> MessageSnapshot {
        MessageSnapshot(messageID: id, logID: id, roomID: roomID, from: UserObject(["user_id": "ada"])!,
                        body: ["text": .string(text), "format": "markdown"])
    }

    func testALoadedMessageShowsItsSenderRoomAndText() async throws {
        let store = await PreviewFixtures.makeStore()
        let session = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let cards = session.placeCards(in: message("see https://link.apron.chat/#server=wss://home.example/ws&room=general&message=1793091780000"))
        XCTAssertEqual(cards, [PlaceCard(
            link: ApronLink(server: home, room: "general", message: id(3)),
            content: .message(sender: "Chiara", preview: "Seeing it too on cellular."),
            roomTitle: "general", memberCount: 6)])
    }

    func testARoomAThreadAndAnUnloadedMessageShowAsTheirRoom() async throws {
        let store = await PreviewFixtures.makeStore()
        let session = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let cards = session.placeCards(in: message("apron:?room=\(releaseThread) and apron:?room=ops&message=\(id(-280).text)"))
        XCTAssertEqual(cards, [
            PlaceCard(link: ApronLink(server: home, room: releaseThread), content: .room, roomTitle: "Release 0.2", isThread: true, memberCount: 3),
            PlaceCard(link: ApronLink(server: home, room: "ops", message: id(-280)), content: .room, roomTitle: "ops", isPrivate: true, memberCount: 2),
        ], "a relative link is this server's; the ops message isn't loaded, so its card is the room's")
    }

    func testAPlaceTheReaderCannotSeeOrTheMessageItselfDrawsNoCard() async throws {
        let store = await PreviewFixtures.makeStore()
        let session = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        XCTAssertEqual(session.placeCards(in: message("apron:?room=secret apron:?room=general&user=ada apron:?server=wss://elsewhere.example/ws&room=general")), [],
                       "an unknown room, a user, and a server not saved")
        XCTAssertEqual(session.placeCards(in: message("apron:?room=design&message=1", id: LogID("1")!)), [], "a link to the message itself")
    }

    func testOnePlaceWrittenTwoWaysIsOneCardAndThreeAtMost() async throws {
        let store = await PreviewFixtures.makeStore()
        let session = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let cards = session.placeCards(in: message(
            "apron:?room=general https://link.apron.chat/#server=wss://home.example/ws&room=general&theme=dark apron:?room=design apron:?room=random apron:?room=kitchen"))
        XCTAssertEqual(cards.map(\.roomTitle), ["general", "design", "random"])
    }

    func testAnotherServersLinkDrawsFromItsSessionWhileSignedIn() async throws {
        let store = await PreviewFixtures.makeStore()
        let session = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let text = message("apron:?server=wss://demo.apron.example/ws&room=lobby&message=\(id(-15).text)")
        XCTAssertEqual(session.placeCards(in: text, sessions: store.liveSession(for:)), [PlaceCard(
            link: ApronLink(server: demo, room: "lobby", message: id(-15)),
            content: .message(sender: "Wren", preview: "Anyone tried the Rust server with email sign-in?"),
            roomTitle: "lobby", memberCount: 3)])
        XCTAssertEqual(session.placeCards(in: text), [], "no other sessions given")
        await store.session(for: PreviewFixtures.demoID)?.stop()
        XCTAssertEqual(session.placeCards(in: text, sessions: store.liveSession(for:)), [], "a server not signed in draws none")
    }

    func testAnEmbedForAPlaceACardShowsIsHidden() {
        let card = PlaceCard(link: ApronLink(server: home, room: "general", message: LogID("5")), content: .room, roomTitle: "general")
        func embed(_ url: String) -> Embed { Embed(["kind": "link", "url": .string(url)])! }
        XCTAssertTrue(PlaceCard.previews(embed("https://link.apron.chat/#room=general&message=5&server=wss://home.example/ws"), in: [card], from: home),
                      "keys in another order")
        XCTAssertTrue(PlaceCard.previews(embed("apron:?room=general&message=5"), in: [card], from: home), "without its server")
        XCTAssertFalse(PlaceCard.previews(embed("apron:?room=general"), in: [card], from: home), "the room, not the message")
        XCTAssertFalse(PlaceCard.previews(embed("apron:?room=general&message=5"), in: [card], from: demo), "another server's")
        XCTAssertFalse(PlaceCard.previews(embed("apron:?room=general&message=5&user=ada"), in: [card], from: home), "a user link")
        XCTAssertFalse(PlaceCard.previews(embed("https://example.com/"), in: [card], from: home))
        XCTAssertFalse(PlaceCard.previews(embed("apron:?room=general&message=5"), in: [], from: home), "no card")
    }
}
