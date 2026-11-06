import XCTest
@testable import ApronKit

/// apron-web's `room-search.test.ts` (#220), over Ladle's `RoomFinder`.
final class RoomFinderTests: XCTestCase {
    private func room(_ id: String, _ title: String, parent: String? = nil, description: String? = nil,
                      joined: Bool = true, active: String? = nil) -> RoomFinder.KnownRoom {
        RoomFinder.KnownRoom(id: id, title: title, parentRoomID: parent, description: description, joined: joined, activeID: active.flatMap(LogID.init))
    }

    private func record(roomID: String, logID: LogID? = nil, parentRoomID: String? = nil, isPrivate: Bool? = nil, title: JSONValue? = nil) -> RoomRecord {
        RoomRecord(roomID: roomID, logID: logID, parentRoomID: parentRoomID, isPrivate: isPrivate, title: title, description: nil, ext: nil)
    }

    func testKnownTakesEachRoomOnceAsHeldElseFromItsRecordLeavingOutAPrivateRecord() {
        let live = [room("general", "General", active: "30"), room("t1", "Deploy", parent: "general", joined: false)]
        let records = [
            record(roomID: "general", logID: LogID("1"), title: .string("Old title")),
            record(roomID: "t3", logID: LogID("5"), parentRoomID: "general", title: .string("Offsite")),
            record(roomID: "hiring", isPrivate: true, title: .string("Hiring")),
            record(roomID: "bare", logID: LogID("2")),
        ]
        XCTAssertEqual(RoomFinder.known(live, records: records), live + [
            room("t3", "Offsite", parent: "general", joined: false, active: "5"),
            room("bare", "bare", joined: false, active: "2"),
        ])
    }

    func testTierRanksTheWholeNameItsStartAWordAnywhereThenTheDescription() {
        func tier(_ typed: String, described: Bool = false) -> RoomFinder.Tier? {
            RoomFinder.tier(id: "deploy-bots", title: "Déploy bots", description: "Release notes", RoomFinder.wanted(typed), described: described)
        }
        XCTAssertEqual(tier("deploy bots"), .whole)
        XCTAssertEqual(tier("deploy-bots"), .whole)
        XCTAssertEqual(tier("#Deploy-Bots"), .whole)
        XCTAssertEqual(tier("dep"), .start)
        XCTAssertEqual(tier("bots"), .word)
        XCTAssertEqual(tier("ots"), .anywhere)
        XCTAssertNil(tier("release"))
        XCTAssertEqual(tier("release", described: true), .description)
        XCTAssertEqual(tier(""), .whole)
    }

    private lazy var known = [
        room("eng", "Engineering", active: "50"),
        room("t-checklist", "Deploy checklist", parent: "eng", active: "40"),
        room("t-freeze", "Deploy freeze", parent: "ops", active: "10"),
        room("bots", "Release bots", description: "Deploy notices", active: "60"),
        room("t-deps", "Dependency upgrades", parent: "eng", joined: false, active: "45"),
        room("departures", "Departures", joined: false, active: "55"),
        room("t-old", "Old deploy keys", parent: "eng", joined: false, active: "5"),
    ]

    func testRankPutsJoinedFirstThenTheBetterMatchThenTheNewer() {
        let found = RoomFinder.rank(known, text: "dep")
        XCTAssertEqual(found.rooms.map(\.room.id), ["t-checklist", "t-freeze", "bots", "departures", "t-deps", "t-old"])
        XCTAssertEqual(found.total, 6)
        XCTAssertEqual(found.scope, [])
    }

    func testWithRoomSearchesOnlyTheThreadsOfTheRoomsItNames() {
        for value in ["eng", "engineering"] {
            let found = RoomFinder.rank(known, text: "dep", rooms: [value])
            XCTAssertEqual(found.rooms.map(\.room.id), ["t-checklist", "t-deps", "t-old"])
            XCTAssertEqual(found.scope.map(\.id), ["eng"])
        }
        XCTAssertEqual(RoomFinder.rank(known, text: "", rooms: ["eng"]).rooms.map(\.room.id), ["t-checklist", "t-deps", "t-old"])
        XCTAssertEqual(RoomFinder.rank(known, text: "", rooms: ["nowhere"]).rooms, [])
    }

    func testWithNothingTypedListsEverythingJoinedAndNewestFirstToTheLimit() {
        let found = RoomFinder.rank(known, text: "  ", limit: 3)
        XCTAssertEqual(found.rooms.map(\.room.id), ["bots", "eng", "t-checklist"])
        XCTAssertEqual(found.total, 7)
    }

    func testHandlesThousandsOfThreads() {
        let many = [room("eng", "Engineering")] + (0 ..< 5000).map {
            room("t\($0)", "Incident \($0)", parent: "eng", joined: $0 % 2 == 0, active: String(1_700_000_000_000 + $0))
        }
        XCTAssertEqual(RoomFinder.rank(many, text: "incident 4999", rooms: ["eng"]).rooms.first?.room.id, "t4999")
        XCTAssertEqual(RoomFinder.rank(many, text: "incident").total, 5000)
    }

    /// room-finder.svelte.test.ts's foot (#224).
    func testTheLineAfterAScopedRoomsResultsSaysWhatTheServerListed() {
        XCTAssertEqual(RoomFinder.ThreadsListing.listing.note(title: "General"), "Listing General’s other threads…")
        XCTAssertEqual(RoomFinder.ThreadsListing.listed(2).note(title: "General"),
                       "Threads you haven’t joined: the 2 the server lists, its most recently active.")
        XCTAssertEqual(RoomFinder.ThreadsListing.listed(1).note(title: "General"),
                       "Threads you haven’t joined: the one the server lists, its most recently active.")
        XCTAssertEqual(RoomFinder.ThreadsListing.listed(0).note(title: "General"), "No threads you haven’t joined, as the server lists them.")
        let failed = RoomFinder.ThreadsListing.failed("too many requests")
        XCTAssertEqual(failed.note(title: "General"), "General’s other threads didn’t list: too many requests")
        XCTAssertEqual([failed.failed, RoomFinder.ThreadsListing.listing.failed], [true, false])
    }

    func testTheComposerListFindsAWordInATitle() {
        let rooms = [RoomSuggestion(id: "bots", title: "Release bots"), RoomSuggestion(id: "botany", title: "Botany")]
        XCTAssertEqual(RoomMentions.search(rooms, "bot").map(\.id), ["botany", "bots"])
    }
}
