import XCTest
@testable import ApronKit

/// The `:` list, as apron-web's `emoji-autocomplete.ts`. The expected lists are what apron-web's
/// own `searchEmoji` returns for the same queries over @emoji-mart/data 1.2.1.
@MainActor
final class StandardEmojiTests: XCTestCase {
    private func found(_ query: String) -> [String] {
        StandardEmoji.search(query).map { "\($0.id) \($0.inserted)" }
    }

    func testTheTableIsTheOneApronWebSearches() {
        XCTAssertEqual(StandardEmojiData.version, "1.2.1")
        XCTAssertEqual(StandardEmojiData.table.split(separator: "\n").count, 1870)
    }

    func testSearchRanksAsApronWebDoes() {
        XCTAssertEqual(found("smi"), ["blush 😊", "face_with_hand_over_mouth 🤭", "grin 😁", "grinning 😀", "heart_eyes 😍", "heart_eyes_cat 😻",
                                      "hugging_face 🤗", "innocent 😇"], "a keyword's start, ties by shortcode")
        XCTAssertEqual(found("thumb"), ["-1 👎", "+1 👍", "hand_with_index_finger_and_thumb_crossed 🫰"], "- before +, as localeCompare")
        XCTAssertEqual(found("heart"), ["heart ❤️", "hand_with_index_finger_and_thumb_crossed 🫰", "heart_eyes 😍", "heart_eyes_cat 😻",
                                        "kissing_heart 😘", "man-heart-man 👨‍❤️‍👨", "two_hearts 💕", "woman-heart-man 👩‍❤️‍👨"],
                       "the shortcode itself first, then a whole keyword")
        XCTAssertEqual(found("+1"), ["+1 👍"])
        XCTAssertEqual(found("satisfied"), ["laughing 😆"], "by alias")
        XCTAssertEqual(found("cat"), ["cat 🐱", "cat2 🐈", "feet 🐾", "tiger 🐯", "butterfly 🦋", "crying_cat_face 😿", "heart_eyes_cat 😻", "joy_cat 😹"])
        XCTAssertEqual(found("flag"), ["cn 🇨🇳", "de 🇩🇪", "es 🇪🇸", "flag-ac 🇦🇨", "flag-ad 🇦🇩", "flag-ae 🇦🇪", "flag-af 🇦🇫", "flag-ag 🇦🇬"])
        XCTAssertEqual(found("face_with"), ["face_vomiting 🤮", "face_with_cowboy_hat 🤠", "face_with_diagonal_mouth 🫤", "face_with_hand_over_mouth 🤭",
                                            "face_with_head_bandage 🤕", "face_with_monocle 🧐", "face_with_open_eyes_and_hand_over_mouth 🫢",
                                            "face_with_peeking_eye 🫣"])
        XCTAssertEqual(found("Ok"), ["ok 🆗", "accept 🉑", "ballot_box_with_check ☑️", "heavy_check_mark ✔️", "white_check_mark ✅", "ok_hand 👌",
                                     "ok_woman 🙆", "arrow_right_hook ↪️"], "ignoring case")
        XCTAssertEqual(found(""), [])
        XCTAssertEqual(StandardEmoji.search("tada").first, EmojiSuggestion(id: "tada", name: "Party Popper", inserted: "🎉"))
    }

    func testTheQueryIsTwoToThirtyTwoShortcodeCharactersAfterAColonThatStartsAWord() {
        XCTAssertEqual(["Lunch :smi", ":+1", ":-1", "x :face_with", "Lunch :D", "12:30", "a:smi", ":", ":s", "Lunch :smi le", "\n:ok",
                        ":" + String(repeating: "a", count: 32), ":" + String(repeating: "a", count: 33), ":é"].map(StandardEmoji.query(in:)),
                       ["smi", "+1", "-1", "face_with", nil, nil, nil, nil, nil, nil, "ok", String(repeating: "a", count: 32), nil, nil])
    }

    func testTheServersCustomEmojiComeFirstAndTogetherAtMostEight() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        await home.loadEmojiCatalog()
        guard case .emoji(let rows) = home.suggestions(for: DraftField(text: "Lunch :smi"), in: PreviewFixtures.emojiRoomID) else {
            return XCTFail("the : list")
        }
        XCTAssertEqual(rows.map(\.id), ["smilingpan", "blush", "face_with_hand_over_mouth", "grin", "grinning", "heart_eyes", "heart_eyes_cat", "hugging_face"])
        XCTAssertEqual(rows.first?.inserted, ":smilingpan:")
        XCTAssertEqual(rows.first?.name, "Smiling frying pan", "its alt")
        XCTAssertEqual(StandardEmoji.suggestions("smi", catalog: nil).count, 8)

        var field = DraftField(text: "Lunch :smi")
        field.insert(rows[1])
        XCTAssertEqual(field.text, "Lunch 😊", "no space after, as apron-web")
        field = DraftField(text: "Lunch :smi")
        field.insert(rows[0])
        XCTAssertEqual(field.text, "Lunch :smilingpan:")
    }
}
