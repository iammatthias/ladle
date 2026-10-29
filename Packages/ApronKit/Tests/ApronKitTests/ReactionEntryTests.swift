@testable import ApronKit
import XCTest

final class ReactionEntryTests: XCTestCase {
    func testEmojiSequencesAndKeys() {
        for sequence in ["👍", "👍🏽", "🏳️‍🌈", "👨‍👩‍👧", "❤️", "❤", "🇳🇴", "1️⃣", "#⃣", "🏴󠁧󠁢󠁳󠁣󠁴󠁿"] {
            XCTAssertTrue(ReactionEntry.isEmojiSequence(sequence), sequence)
        }
        for key in [":partyparrot:", "+1", "12:30", "1", "👍👍", "a👍", ""] {
            XCTAssertFalse(ReactionEntry.isEmojiSequence(key), key)
        }
    }

    func testEntriesCompareWithoutVariationSelectors() {
        XCTAssertEqual(ReactionEntry.key("❤️"), "❤")
        XCTAssertEqual(ReactionEntry.key("🏳️‍🌈"), "🏳‍🌈")
        XCTAssertEqual(ReactionEntry.key(":apron:"), ":apron:")
    }

    func testEntriesThatDifferOnlyInU_FE0FAreOneReaction() {
        var store = ReplayStore()
        store.apply(Records(messageParams: [
            "message_id": "10", "log_id": "10", "room_id": "general", "from": ["user_id": "ada"], "body": ["text": "hi"],
        ]))
        store.apply(Records(reactionsParams: [
            "log_id": "11", "message_id": "10", "room_id": "general", "reactions": [
                ["from": ["user_id": "ada"], "emojis": ["❤", "❤️", ":apron:"]],
                ["from": ["user_id": "bram"], "emojis": ["❤️"]],
            ],
        ]))
        let summaries = store.reactions(on: LogID("10")!)
        XCTAssertEqual(summaries, [
            .init(key: ":apron:", emoji: ":apron:", userIDs: ["ada"]),
            .init(key: "❤", emoji: "❤️", userIDs: ["ada", "bram"]),
        ])
    }
}
