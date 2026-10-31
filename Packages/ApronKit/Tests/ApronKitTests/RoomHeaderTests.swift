import XCTest
@testable import ApronKit

@MainActor
final class RoomHeaderTests: XCTestCase {
    func testAFingerprintIsApronWebsFNV1aInBase36() {
        XCTAssertEqual(HiddenDescriptions.fingerprint("Ship Friday, then freeze"), "19n0wb0")
        XCTAssertEqual(HiddenDescriptions.fingerprint("Pots, pans and :apron:"), "qj8m8c")
        XCTAssertEqual(HiddenDescriptions.fingerprint(""), "ztntfp")
    }

    func testADescriptionPutAwayStaysAwayUntilItIsEditedOrShownAndOutlivesALaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UUID(), key = DraftKey(server: server, roomID: "general")
        let hidden = HiddenDescriptions(directory: directory)
        XCTAssertFalse(hidden.isHidden(key, description: "Ship Friday"))
        hidden.hide(key, description: "Ship Friday")
        XCTAssertTrue(hidden.isHidden(key, description: "Ship Friday"))
        XCTAssertFalse(hidden.isHidden(key, description: "Ship Monday"), "an edit pins it again")
        XCTAssertFalse(hidden.isHidden(DraftKey(server: UUID(), roomID: "general"), description: "Ship Friday"), "by server")

        let relaunched = HiddenDescriptions(directory: directory)
        XCTAssertTrue(relaunched.isHidden(key, description: "Ship Friday"))
        relaunched.show(key)
        XCTAssertFalse(HiddenDescriptions(directory: directory).isHidden(key, description: "Ship Friday"))

        relaunched.hide(key, description: "Ship Friday")
        relaunched.removeAll(server: server)
        XCTAssertFalse(relaunched.isHidden(key, description: "Ship Friday"), "gone with its server")
    }

    func testOnlyTheNewestTwoHundredAreKept() {
        let hidden = HiddenDescriptions()
        let server = UUID()
        for index in 0 ... 200 { hidden.hide(DraftKey(server: server, roomID: "r\(index)"), description: "d") }
        XCTAssertFalse(hidden.isHidden(DraftKey(server: server, roomID: "r0"), description: "d"))
        XCTAssertTrue(hidden.isHidden(DraftKey(server: server, roomID: "r1"), description: "d"))
        XCTAssertEqual(HiddenDescriptions.limit, 200)
    }

    func testTheHeaderLineAndTheRoomsLinkAndReadMark() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        XCTAssertEqual(home.headerLine("design", typing: nil, copied: false, descriptionPutAway: true), .topic("Icons, type and color"))
        XCTAssertNil(home.headerLine("design", typing: nil, copied: false, descriptionPutAway: false), "pinned, it shows under the header instead")
        XCTAssertEqual(home.headerLine("design", typing: "Ada is typing…", copied: false, descriptionPutAway: true), .typing("Ada is typing…"))
        XCTAssertEqual(home.headerLine("design", typing: "Ada is typing…", copied: true, descriptionPutAway: true)?.text, "Link copied")
        XCTAssertEqual(home.headerLine(PreviewFixtures.releaseThreadID, typing: nil, copied: false, descriptionPutAway: true), .replies("4 replies"),
                       "a thread says its replies, never its description")
        XCTAssertEqual(home.link(to: "general")?.absoluteString, "https://link.apron.chat/#server=wss://home.example/ws&room=general")
        XCTAssertTrue(home.mayEdit("general"))
        XCTAssertEqual(home.editableTitle(of: PreviewFixtures.untitledThreadID), "")
        XCTAssertEqual(home.editableTitle(of: "general"), "general")

        XCTAssertEqual(home.unreadCount(in: "general"), 3)
        XCTAssertEqual(home.readMark(of: "general"), home.timeline("general").last?.messageID)
        await home.markAllRead("general")
        XCTAssertEqual(home.unreadCount(in: "general"), 0)
    }
}
