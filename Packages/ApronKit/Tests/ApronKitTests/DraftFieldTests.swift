import XCTest
@testable import ApronKit

@MainActor
final class DraftFieldTests: XCTestCase {
    private func home() async throws -> ServerSession {
        let store = await PreviewFixtures.makeStore()
        return try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
    }

    func testTheQueryIsWhatTheEndOfTheTextTypes() async throws {
        let home = try await home()
        let edit = DraftField(mode: .edit(home.timeline("general")[0]), text: "/inv")
        XCTAssertEqual(["/inv", "/inv x", "//inv", "Thanks @", "hi @ad", "line\n@ad", "Lunch :pa", ":", "Lunch :p a", "Moving this to #s", "a#s", "plain", ""]
            .map { DraftField(text: $0).query }, [.command("inv"), nil, nil, .mention(""), .mention("ad"), nil, .emoji("pa"), nil, nil, .room("s"), nil, nil, nil])
        XCTAssertNil(edit.query, "an edit is never a command")
        XCTAssertEqual(DraftField(mode: edit.mode, text: "Thanks @").query, .mention(""), "an edit lists people")
        XCTAssertEqual(DraftField(mode: edit.mode, text: "Lunch :pa").query, .emoji("pa"))
        XCTAssertEqual(DraftField(mode: edit.mode, text: "see #s").query, .room("s"))
    }

    func testSuggestionsListTheRoomsOtherMembersEmojiAndRooms() async throws {
        let home = try await home()
        func people(_ text: String) -> [String]? {
            guard case .people(let found) = home.suggestions(for: DraftField(text: text), in: "general") else { return nil }
            return found.map(\.userID)
        }
        XCTAssertEqual(people("Thanks @"), ["ada", "bram", "chiara", "eunji", "dev"], "online first, never you")
        XCTAssertEqual(people("@CH"), ["chiara"], "by name, ignoring case")
        XCTAssertEqual(people("@eun"), ["eunji"])
        XCTAssertNil(people("@zed"))
        XCTAssertNil(home.suggestions(for: DraftField(text: "@zed"), in: "general"), "nothing matches, no list")
        XCTAssertEqual(home.suggestions(for: DraftField(text: "Lunch :pa"), in: "kitchen"),
                       .emoji(home.emojiCatalog.map { $0.offered.filter { $0.key == ":partyparrot:" } } ?? []))
        guard case .rooms(let rooms) = home.suggestions(for: DraftField(text: "Moving this to #s"), in: "general") else { return XCTFail("rooms") }
        XCTAssertEqual(rooms.map(\.title), ["design", "Icon sketches", "ops", "Release 0.2"])
        XCTAssertNil(home.suggestions(for: DraftField(text: "/inv"), in: "general"), "no commands before /help answers")
        await home.loadCommands(in: "general")
        for _ in 0 ..< 100 where home.commands == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard case .commands(let commands) = home.suggestions(for: DraftField(text: "/inv"), in: "general") else { return XCTFail("commands") }
        XCTAssertEqual(commands.map(\.name), ["invite-bot", "invite-device"], "in the server's order")
    }

    func testPickingPutsTheChoiceInPlaceOfWhatIsTyped() async throws {
        let home = try await home()
        var field = DraftField(text: "Thanks @ad")
        field.insert(mention: "ada", named: "Ada")
        XCTAssertEqual(field.text, "Thanks @Ada ")
        XCTAssertEqual(field.mentions, ["ada": "Ada"])
        var emoji = DraftField(text: "Lunch :pa")
        emoji.insert(try XCTUnwrap(home.emojiCatalog?.offered.first { $0.key == ":partyparrot:" }))
        XCTAssertEqual(emoji.text, "Lunch :partyparrot: ")
        var room = DraftField(text: "Moving this to #s")
        room.insert(room: "design")
        XCTAssertEqual(room.text, "Moving this to #design ")
        var command = DraftField(text: "/inv")
        command.insert(ServerCommand(name: "invite-device", usage: "/invite-device list|add|remove [<id>]", summary: "A token"))
        XCTAssertEqual(command.text, "/invite-device ")
    }

    func testAMentionGoesWhileTheTextShowsIt() {
        var field = DraftField(text: "  @Ada and @Bram  ", mentions: ["ada": "Ada", "bram": "Bram", "chiara": "Chiara"])
        XCTAssertEqual(field.sentText, "@Ada and @Bram")
        XCTAssertEqual(field.sentMentions, ["ada", "bram"])
        field.text = "@Bram"
        XCTAssertEqual(field.sentMentions, ["bram"])
    }

    func testAnEditOpensWithTheMentionsItsTextShows() async throws {
        let home = try await home()
        let mention = try XCTUnwrap(home.timeline("general").first { !$0.mentionIDs.isEmpty })
        let field = DraftField(editing: mention, in: home)
        XCTAssertEqual(field.text, "@Sam can you review the icon PR before then? It's small, mostly the ladle glyph at 20 pt.")
        XCTAssertEqual(field.mentions, ["sam": "Sam"])
        XCTAssertEqual(field.target?.messageID, mention.messageID)
        XCTAssertTrue(field.isEdit)
        let plain = try XCTUnwrap(home.timeline("general").first { $0.mentionIDs.isEmpty })
        XCTAssertEqual(DraftField(editing: plain, in: home).mentions, [:])
    }

    func testSendNeedsTextOrAFileAndNothingPreparing() async throws {
        let home = try await home()
        XCTAssertEqual([DraftField(text: "hi").canSend(readyFiles: 0, preparing: false),
                        DraftField(text: "  \n").canSend(readyFiles: 0, preparing: false),
                        DraftField(text: "").canSend(readyFiles: 1, preparing: false),
                        DraftField(text: "hi").canSend(readyFiles: 1, preparing: true),
                        DraftField(text: String(repeating: "a", count: TextLimit.maxBytes + 1)).canSend(readyFiles: 0, preparing: false),
                        DraftField(mode: .edit(home.timeline("general")[0]), text: "").canSend(readyFiles: 1, preparing: false)],
                       [true, false, true, false, false, false])
    }
}
