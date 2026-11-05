import XCTest
@testable import ApronKit

/// Load More from Server under Search Local History (apron-web #220), on the changelog: 200
/// messages paged eight at a time, its newest page and a window around its sixth message loaded,
/// a hole between them.
@MainActor
final class SearchLoadMoreTests: XCTestCase {
    func testLoadMorePagesOlderMessagesIntoTheRoomsSearchedHolesFirstUntilEverythingIsSearched() async throws {
        let store = await PreviewFixtures.makeHoleStore()
        let changelog = try XCTUnwrap(store.session(for: PreviewFixtures.holeID))
        let query = "room:#changelog green"
        let before = await changelog.search(query).messages.count
        XCTAssertEqual(before, 2, "#1008 in the window and #1192 in the newest page")
        XCTAssertEqual(changelog.searchLoadOffer(for: query, loading: false, error: nil),
                       SearchLoadOffer(note: "Older messages in changelog are on the server.", done: false, busy: false))

        var presses = 0
        while changelog.searchLoadOffer(for: query, loading: false, error: nil)?.done == false, presses < 40 {
            let failed = await changelog.loadMoreForSearch(query)
            XCTAssertNil(failed)
            presses += 1
        }
        XCTAssertEqual(changelog.searchLoadOffer(for: query, loading: false, error: nil),
                       SearchLoadOffer(note: "Everything the server has in changelog is loaded, and searched.", done: true, busy: false))
        XCTAssertEqual(presses, 24, "23 pages down through the hole, then one below the window")
        XCTAssertEqual(changelog.holes(in: PreviewFixtures.holeRoomID), [])
        let found = await changelog.search(query).messages.map { MessageText.plain($0.body) }
        XCTAssertEqual(found.count, 25, "every eighth of 200")
        XCTAssertEqual([found.first, found.last], ["#1192 Build is green again.", "#1000 Build is green again."])
    }

    func testLoadMoreIsOfferedOnlyForASearchAndSaysWhereAndWhyItFailed() async throws {
        let store = await PreviewFixtures.makeHoleStore()
        let changelog = try XCTUnwrap(store.session(for: PreviewFixtures.holeID))
        XCTAssertNil(changelog.searchLoadOffer(for: "  ", loading: false, error: nil), "nothing typed")
        XCTAssertNil(changelog.searchLoadOffer(for: "room:#nowhere green", loading: false, error: nil), "no room searched")
        XCTAssertEqual(changelog.searchLoadOffer(for: "green", loading: true, error: nil),
                       SearchLoadOffer(note: "Older messages in your rooms are on the server.", done: false, busy: true))
        XCTAssertEqual(changelog.searchLoadOffer(for: "green", loading: false, error: "The server didn’t send them: Offline.")?.note,
                       "The server didn’t send them: Offline.")
    }
}
