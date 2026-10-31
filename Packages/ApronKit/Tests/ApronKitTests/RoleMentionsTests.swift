import XCTest
@testable import ApronKit

@MainActor
final class RoleMentionsTests: XCTestCase {
    private func person(_ id: String, _ roles: [String]) -> UserObject {
        UserObject(["user_id": .string(id), "roles": .array(roles.map(JSONValue.string))])!
    }

    func testRolesAreThoseOthersHoldMostHeldFirstAndWritableAsOneID() {
        let people = [person("me", ["mod", "solo"]), person("ada", ["mod", "on call", "admin", "mod"]), person("bob", ["mod", "bot"]),
                      person("cy", ["admin"])]
        let roles = RoleMentions.roles(of: people, you: "me", roles: \.roles)
        XCTAssertEqual(roles, [RoleSuggestion(role: "admin", members: ["ada", "cy"]), RoleSuggestion(role: "mod", members: ["ada", "bob"]),
                               RoleSuggestion(role: "bot", members: ["bob"])],
                       "not yours alone, not one with a space, each holder once, ties by name")
        XCTAssertEqual(["mod", "on call", "a.b", "-x", "x-", "ops@home"].map(RoleMentions.isMentionable), [true, false, true, false, false, true])
    }

    func testSearchPutsTheExactRoleFirstAndAnAmpersandAsksForRolesOnly() {
        let roles = [RoleSuggestion(role: "moderators", members: ["a", "b"]), RoleSuggestion(role: "mod", members: ["a"]),
                     RoleSuggestion(role: "bot", members: ["c"])]
        XCTAssertEqual(RoleMentions.search(roles, "mod").map(\.role), ["mod", "moderators"])
        XCTAssertEqual(RoleMentions.search(roles, "&MO").map(\.role), ["moderators", "mod"])
        XCTAssertEqual(RoleMentions.search(roles, "mod ").map(\.role), ["mod"], "a space after the name keeps only the exact role")
        XCTAssertEqual(RoleMentions.search(roles, "&").map(\.role), ["moderators", "mod", "bot"])
        XCTAssertEqual(RoleMentions.search(roles, "x").map(\.role), [])
    }

    func testTheAtListMixesPeopleAndRolesAsTheWebDoes() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        func list(_ word: String) -> [String] {
            home.mentionSuggestions(word, in: "general").map {
                switch $0 {
                case .person(let person): person.userID
                case .role(let role): "&\(role.role):\(role.members.joined(separator: ","))"
                }
            }
        }
        XCTAssertEqual(list(""), ["ada", "bram", "chiara", "eunji", "dev", "&announce:chiara,eunji", "&admin:ada", "&bot:dev"],
                       "five people, then roles in the three places left, most held first")
        XCTAssertEqual(list("&"), ["&announce:chiara,eunji", "&admin:ada", "&bot:dev", "&mod:chiara"], "roles alone")
        XCTAssertEqual(list("&mo"), ["&mod:chiara"])
        XCTAssertEqual(list("bot"), ["&bot:dev"])
        XCTAssertEqual(list("a"), ["ada", "bram", "chiara", "&announce:chiara,eunji", "&admin:ada"], "people containing it, roles starting with it")
        XCTAssertEqual(home.suggestions(for: DraftField(text: "Ping @&mo"), in: "general"),
                       .mentions([.role(RoleSuggestion(role: "mod", members: ["chiara"]))]))
    }

    func testAPickedRoleIsWrittenAsSentAndMentionsItsHoldersInPlace() {
        var field = DraftField(text: "@Bram can @&mo", mentions: ["bram": "Bram"])
        field.insert(role: "mod")
        XCTAssertEqual(field.text, "@Bram can @&mod ")
        field.text += "or @Ada look, @&nobody"
        field.mentions["ada"] = "Ada"
        XCTAssertEqual(field.sentMentions(holders: ["mod": ["chiara", "ada"]]), ["bram", "chiara", "ada"],
                       "in the order written, the role's holders where it stands, each once")
        XCTAssertEqual(field.sentMentions(), ["bram", "ada"], "a role nobody here holds mentions nobody")
        XCTAssertEqual(DraftField(text: "x@&mod").sentMentions(holders: ["mod": ["chiara"]]), [], "not right after a letter")
    }

    func testARoleRendersAsAChipThatReadsAtRoleOutsideCode() {
        let body: JSONValue = ["text": "@&announce see `@&announce` and x@&mod, @&nobody.", "format": "markdown"]
        let text = MessageText.attributed(body, mentions: ["announce": "announce"])
        XCTAssertEqual(String(text.characters), "@announce see @&announce and x@&mod, @nobody.")
        let chips = text.runs.compactMap { run in run[RoleMentionKey.self].map { "\(String(text[run.range].characters))=\($0)" } }
        XCTAssertEqual(chips, ["@announce=announce", "@nobody=nobody"], "any role, known or not; never in code or after a letter")
        XCTAssertEqual(text.runs.compactMap { $0[MentionKey.self] }, [], "@&announce is not a mention of a user named announce")
        XCTAssertEqual(MessageText.plain(body), "@announce see @&announce and x@&mod, @nobody.")
        XCTAssertEqual(MessageText.plain(["text": "@&mod hi"]), "@mod hi")
    }

    func testOnlyBeingListedMentionsYouNotHoldingTheRole() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let message = try XCTUnwrap(home.timeline("design").last)
        XCTAssertEqual(message.mentionIDs, ["eunji"])
        XCTAssertFalse(MessageRowModel(message, in: home).mentionsYou, "Sam reads @&announce without being listed")
        XCTAssertEqual(home.mentionCount(in: "design"), 0)
    }
}
