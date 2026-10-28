import XCTest
@testable import ApronKit

@MainActor
final class PreviewFixturesTests: XCTestCase {
    func testTheSeedHoldsEveryStateTheScreenshotsShow() async throws {
        let store = await PreviewFixtures.makeStore()
        XCTAssertEqual(store.records.map(\.label), ["Home", "Apron Demo"])
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let demo = try XCTUnwrap(store.session(for: PreviewFixtures.demoID))
        XCTAssertEqual(home.status, .signedIn)
        XCTAssertEqual(demo.status, .signedIn)

        XCTAssertEqual(home.roomTree.map { home.title(of: $0.roomID) }, ["design", "general", "ops", "random"])
        XCTAssertEqual(home.roomTree.map { $0.threadIDs.map(home.title(of:)) }, [["Icon sketches"], ["Release 0.2"], [], []])

        let general = home.timeline(PreviewFixtures.busyRoomID)
        XCTAssertEqual(general.count, 13)
        let deleted = home.store.messages(in: PreviewFixtures.busyRoomID).filter(\.isTombstone)
        XCTAssertEqual(deleted.count, 1, "one deleted message, left out of the timeline")
        XCTAssertEqual(general.filter { $0.logID != $0.messageID }.count, 1, "one edit")
        XCTAssertEqual(general.compactMap(\.replyTo).count, 4)
        XCTAssertEqual(general.compactMap(\.replyTo).filter { home.store.message($0)?.isTombstone == true }, deleted.map(\.messageID),
                       "one reply quotes the deleted message")
        let notes = try XCTUnwrap(general.first { $0.body?["text"]?.stringValue?.hasPrefix("Notes from the sync") == true })
        XCTAssertEqual(home.store.reactions(on: notes.messageID)?.map(\.emoji), ["🎉", "👍"], "code point order")
        XCTAssertEqual(home.store.reactions(on: notes.messageID)?.last?.userIDs, ["bram", "chiara", "sam"])
        XCTAssertNotNil(home.store.message(PreviewFixtures.replyTargetID))

        XCTAssertEqual(home.unreadCount(in: "general"), 3, "minutes 15, 16 and 20: Sam's own at 14 says he read through it")
        XCTAssertEqual(general.filter { $0.body?["mentions"]?.arrayValue?.contains("sam") == true }.count, 1, "one mention of you")
        XCTAssertEqual(general.compactMap(\.prevRoomID), ["ops"], "one moved message")
        XCTAssertEqual(general.compactMap { $0.body?["embeds"]?.arrayValue?.first?["kind"]?.stringValue }, ["link", "poll"])
        XCTAssertEqual(home.store.room("ops")?.isPrivate, true)
        XCTAssertEqual(home.notices.map(\.roomID), ["general"])
        XCTAssertEqual(home.store.room(home.roomTree[1].threadIDs[0])?.description?.stringValue, "Ship Friday, then freeze")
        XCTAssertEqual(home.unreadCount(in: "random"), 0, "Sam's pending upload is the newest message")
        let uploads = home.timeline(PreviewFixtures.mediaRoomID).flatMap(\.embedList).compactMap(\.upload)
        XCTAssertEqual(uploads.map { upload -> String in
            switch upload {
            case .pending: "pending"
            case .image(let media): "image \(media.width ?? 0)x\(media.height ?? 0)"
            case .video: "video"
            case .audio: "audio"
            case .file: "file"
            }
        }, ["image 1600x1200", "video", "file", "audio", "pending"])
        XCTAssertTrue(home.canAttach)
        XCTAssertEqual(home.timeline(home.roomTree[1].threadIDs[0]).count, 4, "Release 0.2")
        XCTAssertEqual(home.unreadCount(in: home.roomTree[1].threadIDs[0]), 2)
        XCTAssertEqual(home.unreadCount(in: "design"), 0)
        XCTAssertEqual(demo.unreadCount(in: "lobby"), 3)
        XCTAssertEqual(home.users.user("chiara")?["status"]?.stringValue, "dnd")
    }
}
