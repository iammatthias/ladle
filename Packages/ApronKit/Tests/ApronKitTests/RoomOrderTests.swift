import XCTest
@testable import ApronKit

/// apron-web's `room-order.svelte.test.ts`, and the rooms list's folds (#145, #148, #151).
@MainActor
final class RoomOrderTests: XCTestCase {
    func testInOrderListsThePlacedRoomsByTheirPlaceThenTheRestAsGiven() {
        XCTAssertEqual(RoomOrder.inOrder(["c", "new", "a", "b", "other"], ["a", "b", "gone", "c"]), ["a", "b", "c", "new", "other"])
        XCTAssertEqual(RoomOrder.inOrder(["b", "a"], []), ["b", "a"])
    }

    func testMoveNextMovesARoomJustBeforeOrAfterAnotherWhichStaysPut() {
        XCTAssertEqual(RoomOrder.moveNext(["a", "b", "c", "d"], "d", "b", .before), ["a", "d", "b", "c"])
        XCTAssertEqual(RoomOrder.moveNext(["a", "b", "c", "d"], "a", "c", .after), ["b", "c", "a", "d"])
        XCTAssertEqual(RoomOrder.moveNext(["a", "b", "c"], "a", "c", .after), ["b", "c", "a"])
        XCTAssertEqual(RoomOrder.moveNext(["a", "b"], "a", "a", .after), ["a", "b"], "onto itself")
        XCTAssertEqual(RoomOrder.moveNext(["a", "b"], "x", "a", .before), ["a", "b"], "a room it does not have")
    }

    func testEachRoomIsPlacedTheFirstTimeItIsListedAfterTheOthers() {
        var order = RoomOrder.adopting(["b", "a"], into: [])
        order = RoomOrder.adopting(["a", "c", "b"], into: order)
        XCTAssertEqual(order, ["b", "a", "c"])
        let full = RoomOrder.adopting((0 ..< 300).map { "old\($0)" }, into: [])
        XCTAssertEqual(RoomOrder.adopting(["old5", "new"], into: full), ["old5", "new"], "past 300, the rooms no longer listed go")
    }

    func testAStepGoesPastTheNextRoomShownSoHiddenOnesKeepTheirPlaces() {
        let order = RoomOrder.moveNext(["a", "b", "c", "d"], "d", "a", .before)
        XCTAssertEqual(order, ["d", "a", "b", "c"])
        let up = RoomOrder.stepping(order, "c", among: ["d", "c"], by: -1)
        XCTAssertEqual(up, ["c", "d", "a", "b"], "a and b folded away keep their places")
        XCTAssertNil(RoomOrder.stepping(["c", "d", "a", "b"], "d", among: ["c", "d"], by: 1), "already last shown")
        XCTAssertNil(RoomOrder.stepping(["c", "d", "a", "b"], "c", among: ["c", "d"], by: -1), "already first")
        XCTAssertEqual(RoomOrder.stepping(["c", "d", "a", "b"], "c", among: ["c", "d"], by: 1), ["d", "c", "a", "b"])
    }

    func testADropLandsAfterTheRoomShownBeforeItOrBeforeTheNextAtTheTop() {
        let order = ["a", "b", "c", "d", "e"]
        XCTAssertEqual(RoomOrder.dropping(order, "e", at: 1, among: ["a", "c", "e"]), ["a", "e", "b", "c", "d"],
                       "after a, so b, hidden, stays after it")
        XCTAssertEqual(RoomOrder.dropping(order, "c", at: 0, among: ["b", "c", "e"]), ["a", "c", "b", "d", "e"], "at the top: before b")
        XCTAssertEqual(RoomOrder.dropping(order, "a", at: 0, among: ["a"]), order, "alone in its section")
    }

    func testTheArrangementIsKeptPerAccountAcrossALaunchAndGoesWithItsServer() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UUID(), ada = ArrangementKey(server: server, account: "ada"), bob = ArrangementKey(server: server, account: "bob")
        let arrangement = RoomArrangement(directory: directory)
        arrangement.adopt(["b", "a"], ada)
        arrangement.adopt(["a", "c", "b"], ada)
        arrangement.foldThreads("a", true, ada)
        XCTAssertEqual(arrangement.order(bob), [])

        let relaunched = RoomArrangement(directory: directory)
        XCTAssertEqual(relaunched.order(ada), ["b", "a", "c"])
        XCTAssertTrue(relaunched.threadsFolded("a", ada))
        XCTAssertFalse(relaunched.threadsFolded("a", bob))
        relaunched.foldThreads("a", false, ada)
        XCTAssertFalse(RoomArrangement(directory: directory).threadsFolded("a", ada))

        relaunched.rename(server: server, from: "ada", to: "ada2")
        XCTAssertEqual(RoomArrangement(directory: directory).order(ArrangementKey(server: server, account: "ada2")), ["b", "a", "c"])
        relaunched.removeAll(server: server)
        XCTAssertEqual(RoomArrangement(directory: directory).order(ArrangementKey(server: server, account: "ada2")), [])
    }

    func testTheFoldsKeepTheNewest200() {
        let arrangement = RoomArrangement(), key = ArrangementKey(server: UUID(), account: "ada")
        for index in 0 ..< 201 { arrangement.foldThreads("room\(index)", true, key) }
        XCTAssertFalse(arrangement.threadsFolded("room0", key), "folded longest ago, unfolded first")
        XCTAssertTrue(arrangement.threadsFolded("room1", key))
        XCTAssertTrue(arrangement.threadsFolded("room200", key))
    }

    func testTheFixturesRoomsKeepTheOrderTheyWereGivenAndMoveByKeyOrDrag() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let titles = { home.publicRoomTree.map { home.title(of: $0.roomID) } }
        XCTAssertEqual(titles(), ["design", "general", "kitchen", "markdown", "random", "remote"], "first listed by title")
        let shown = home.publicRoomTree.map(\.roomID)
        XCTAssertTrue(home.moveRoom("random", by: -1, among: shown))
        XCTAssertEqual(titles(), ["design", "general", "kitchen", "random", "markdown", "remote"])
        XCTAssertFalse(home.moveRoom("design", by: -1, among: shown), "already at the top")
        home.moveRooms(home.publicRoomTree.map(\.roomID), fromOffsets: IndexSet(integer: 5), toOffset: 0)
        XCTAssertEqual(titles(), ["remote", "design", "general", "kitchen", "random", "markdown"], "List.onMove's offsets")
        home.moveRooms(home.publicRoomTree.map(\.roomID), fromOffsets: IndexSet(integer: 0), toOffset: 6)
        XCTAssertEqual(titles(), ["design", "general", "kitchen", "random", "markdown", "remote"])
        XCTAssertEqual(home.privateRoomTree.map { home.title(of: $0.roomID) }, ["Ada Okafor", "Bram, Chiara", "Launch plan", "ops"],
                       "Private keeps its own rooms in the one order")
    }

    func testAFoldedSectionShowsTheRoomsWithNewsAndTheOneOpen() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let names = { (nodes: [RoomNode]) in nodes.map { home.title(of: $0.roomID) } }
        XCTAssertEqual(names(home.shownRooms(home.publicRoomTree, folded: false, open: nil)), ["design", "general", "kitchen", "markdown", "random", "remote"])
        XCTAssertEqual(names(home.shownRooms(home.publicRoomTree, folded: true, open: nil)), ["general"], "the rest are read")
        XCTAssertEqual(names(home.shownRooms(home.publicRoomTree, folded: true, open: "markdown")), ["general", "markdown"],
                       "the open room stays")
        XCTAssertEqual(names(home.shownRooms(home.publicRoomTree, folded: true, open: PreviewFixtures.linkCardRoomID)), ["design", "general"],
                       "a thread open is its room open")
        await home.markAllRead("general")
        XCTAssertEqual([home.unreadCount(in: "general"), home.unreadCount(in: PreviewFixtures.releaseThreadID)], [0, 2])
        XCTAssertEqual(names(home.shownRooms(home.publicRoomTree, folded: true, open: nil)), ["general"], "news in a thread joined keeps its room")
        XCTAssertEqual(names(home.shownRooms(home.privateRoomTree, folded: true, open: nil)), ["Ada Okafor"])
    }

    func testPickingTheOpenRoomAgainFoldsItsThreadsToThoseWithNews() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let general = try XCTUnwrap(home.roomTree.first { $0.roomID == "general" })
        XCTAssertFalse(home.threadsFolded("general"))
        home.foldThreads("general", true)
        XCTAssertTrue(home.threadsFolded("general"))
        let folded = home.threadList(of: general, open: "general", now: PreviewFixtures.now, threadsFolded: true)
        XCTAssertEqual(folded.joined.map(home.title(of:)), ["Release 0.2"], "only the thread with news")
        XCTAssertEqual([folded.inactiveCount, folded.othersCount], [0, 0], "no Inactive, no Other Threads")
        let reading = home.threadList(of: general, open: PreviewFixtures.untitledThreadID, now: PreviewFixtures.now, threadsFolded: true)
        XCTAssertEqual(reading.joined.map(home.title(of:)), ["Release 0.2", "Untitled"], "and the one being read")
    }
}
