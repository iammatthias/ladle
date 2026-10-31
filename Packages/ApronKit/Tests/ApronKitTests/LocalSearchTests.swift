import XCTest
@testable import ApronKit

final class LocalSearchTests: XCTestCase {
    private func user(_ id: String, _ name: String? = nil) -> UserObject {
        UserObject(name.map { ["user_id": .string(id), "name": .string($0)] } ?? ["user_id": .string(id)])!
    }

    private func message(_ id: String, _ text: String, log: String? = nil, room: String = "general", from: UserObject? = nil, deleted: Bool? = nil) -> MessageSnapshot {
        MessageSnapshot(messageID: LogID(id)!, logID: LogID(log ?? id)!, roomID: room, from: from ?? user("ada"),
                        body: ["text": .string(text)], deleted: deleted)
    }

    private func marked(_ parts: [SnippetPart]) -> String {
        parts.map { $0.match ? "[\($0.text)]" : $0.text }.joined()
    }

    // MARK: matchesText

    func testMatchesTheTextAsTypedInAnyCaseWithOrWithoutAccentsAnySpacesAsOne() {
        let text = LocalSearch.parse("  Café   DEPLOY ").text
        XCTAssertEqual(text, "cafe deploy")
        XCTAssertTrue(LocalSearch.matchesText(message("1", "Meet at the CAFÉ\n  deploy first"), text))
        XCTAssertFalse(LocalSearch.matchesText(message("2", "The deploy is at the café"), text))
        XCTAssertTrue(LocalSearch.matchesText(message("3", "cafe deploying"), text))
    }

    func testTakesAnyKindOfSpaceAsOneAloneOrInARun() {
        let text = LocalSearch.parse("ship it").text
        XCTAssertTrue(LocalSearch.matchesText(message("1", "ship\tit"), text))
        XCTAssertTrue(LocalSearch.matchesText(message("2", "Ship\nIT now"), text))
        XCTAssertTrue(LocalSearch.matchesText(message("3", "ship it"), text))
        XCTAssertTrue(LocalSearch.matchesText(message("4", " ship \n it "), text))
        XCTAssertTrue(LocalSearch.matchesText(message("5", "shïp it"), text))
        XCTAssertFalse(LocalSearch.matchesText(message("6", "shipit"), text))
    }

    func testNeverMatchesADeletedMessageOneWithoutTextOrAnEmptyQuery() {
        XCTAssertFalse(LocalSearch.matchesText(message("1", "deploy", log: "2", deleted: true), "deploy"))
        var bare = message("1", "")
        bare.body = [:]
        XCTAssertFalse(LocalSearch.matchesText(bare, "deploy"))
        XCTAssertFalse(LocalSearch.matchesText(message("1", "deploy"), LocalSearch.parse("   ").text))
    }

    // MARK: newestMatches

    func testKeepsEachMessageOnceAsItsLatestSnapshotNewestPostedFirstUpToTheLimit() {
        let kept = [message("10", "old text"), message("30", "third")]
        let loaded = [message("10", "edited text", log: "40"), message("20", "second")]
        let found = LocalSearch.newestMatches([kept, loaded], limit: 2)
        XCTAssertEqual(found.messages.map(\.messageID.text), ["30", "20"])
        XCTAssertEqual(found.messages.map { $0.body?["text"]?.stringValue }, ["third", "second"])
        XCTAssertTrue(found.more)
        let all = LocalSearch.newestMatches([kept, loaded])
        XCTAssertEqual(all.messages.map { $0.body?["text"]?.stringValue }, ["third", "second", "edited text"])
        XCTAssertFalse(all.more)
    }

    // MARK: snippet

    func testMarksEachPlaceItHoldsTheTextAsWritten() {
        XCTAssertEqual(LocalSearch.snippet("Meet at the Café, then  the café.", found: "the cafe"), [
            SnippetPart("Meet at ", match: false), SnippetPart("the Café", match: true), SnippetPart(", then ", match: false),
            SnippetPart("the café", match: true), SnippetPart(".", match: false),
        ])
    }

    func testShowsAboutWidthAroundTheFirstMatchOnOneLineCutAtWords() {
        let long = String(repeating: "lorem ipsum ", count: 20) + "the deploy\nfailed " + String(repeating: "dolor sit ", count: 20)
        XCTAssertEqual(marked(LocalSearch.snippet(long, found: "deploy", width: 60)), "…lorem ipsum the [deploy] failed dolor sit dolor sit dolor…")
    }

    func testStartsAtTheBeginningWhenTheMatchIsNearIt() {
        XCTAssertEqual(LocalSearch.snippet("deploy now", found: "deploy"), [SnippetPart("deploy", match: true), SnippetPart(" now", match: false)])
    }

    func testMarksAWordAfterTextOutsideTheBasicPlaneAndADecomposedAccent() {
        XCTAssertEqual(marked(LocalSearch.snippet("😀 deploy", found: "deploy")), "😀 [deploy]")
        XCTAssertEqual(marked(LocalSearch.snippet("cafe\u{301} ok", found: "cafe")), "[cafe\u{301}] ok")
        XCTAssertEqual(marked(LocalSearch.snippet("nothing here", found: "zzz")), "nothing here")
    }

    // MARK: parse

    func testTakesUserAndRoomAsFiltersByIdOrNameQuotedWithSpacesAndTheRestAsText() {
        XCTAssertEqual(LocalSearch.parse("deploy user:@Ada room:#General"), SearchQuery(text: "deploy", users: ["ada"], rooms: ["general"]))
        XCTAssertEqual(LocalSearch.parse("the USER:\"Ada Lovelace\" user:bob room:\"Deploy checklist\" late one"),
                       SearchQuery(text: "the late one", users: ["ada lovelace", "bob"], rooms: ["deploy checklist"]))
        XCTAssertEqual(LocalSearch.parse("room:ops room:#OPS"), SearchQuery(text: "", users: [], rooms: ["ops"]))
    }

    func testKeepsAnythingElseWithAColonAsTextDropsAnEmptyFilterAndQuotesAroundAllOfIt() {
        XCTAssertEqual(LocalSearch.parse("at 14:30 https://example.com user:"), SearchQuery(text: "at 14:30 https://example.com", users: [], rooms: []))
        XCTAssertEqual(LocalSearch.parse("nouser:ada"), SearchQuery(text: "nouser:ada", users: [], rooms: []))
        XCTAssertEqual(LocalSearch.parse(" \"Hello  world\" ").text, "hello world")
        XCTAssertEqual(LocalSearch.parse("say \"hi\" now").text, "say \"hi\" now")
    }

    func testReadsFiltersAndFoldsAsJavaScriptDoes() {
        XCTAssertEqual(LocalSearch.parse("uſer:ada"), SearchQuery(text: "uſer:ada", users: [], rooms: []))
        XCTAssertEqual(LocalSearch.parse("user:\"Ada Love deploy"), SearchQuery(text: "", users: ["ada love deploy"], rooms: []))
        XCTAssertEqual(["ΟΔΟΣ", "İSTANBUL", "Zoë", "ǅ"].map(LocalSearch.folded), ["οδος", "istanbul", "zoe", "ǆ"])
    }

    // MARK: matcher

    private let ada = UserObject(["user_id": "ada", "name": "Ada Lovelace"])!

    private var context: SearchContext {
        SearchContext(users: [ada, user("bob", "Bob")],
                      rooms: [.init(id: "general", title: "General"), .init(id: "thread_deploy", title: "Deploy checklist", parentRoomID: "general"), .init(id: "ops", title: "Ops")],
                      parentOf: { $0 == "thread_unseen" ? "general" : nil })
    }

    private var all: [MessageSnapshot] {
        let sent = { (id: String, room: String, from: UserObject, text: String) in self.message(id, text, room: room, from: from) }
        return [
            sent("1", "general", ada, "the deploy is done"), sent("2", "thread_deploy", user("bob"), "the deploy is done"), sent("3", "ops", ada, "lunch?"),
            sent("4", "thread_unseen", user("carol", "Carol"), "the deploy is done"), sent("5", "elsewhere", user("dave"), "the deploy is done"),
        ]
    }

    private func ids(_ query: String) -> [String] {
        all.filter(LocalSearch.matcher(LocalSearch.parse(query), in: context)!).map(\.messageID.text)
    }

    func testKeepsWhatAUserSentByIdOrNameAsKnownOrAsTheMessageCarriesIt() {
        XCTAssertEqual(ids("user:@ada"), ["1", "3"])
        XCTAssertEqual(ids("user:\"ada lovelace\" deploy"), ["1"])
        XCTAssertEqual(ids("user:carol"), ["4"])
        XCTAssertEqual(ids("user:@ada user:bob"), ["1", "2", "3"])
    }

    func testKeepsWhatIsInARoomAndItsThreadsByIdOrTitleShownOrNot() {
        XCTAssertEqual(ids("room:#general"), ["1", "2", "4"])
        XCTAssertEqual(ids("room:\"deploy checklist\""), ["2"])
        XCTAssertEqual(ids("room:#elsewhere"), ["5"])
        XCTAssertEqual(ids("room:#general user:bob"), ["2"])
    }

    func testAsksForNothingWithoutWordsOrFiltersAndNeverKeepsADeletedMessage() {
        XCTAssertNil(LocalSearch.matcher(LocalSearch.parse("  "), in: context))
        let matches = LocalSearch.matcher(LocalSearch.parse("user:@ada"), in: context)!
        XCTAssertFalse(matches(message("9", "x", log: "10", from: ada, deleted: true)))
    }

    // MARK: filterAtCaret and withFilterValue

    func testFindsTheFilterValueTheCaretIsInWithOrWithoutItsSigil() {
        XCTAssertEqual(LocalSearch.filterAtCaret("deploy user:@ad", caret: 15), FilterAtCaret(kind: .users, start: 12, end: 15, typed: "ad"))
        XCTAssertEqual(LocalSearch.filterAtCaret("room:gen", caret: 8), FilterAtCaret(kind: .rooms, start: 5, end: 8, typed: "gen"))
        XCTAssertEqual(LocalSearch.filterAtCaret("ROOM:#", caret: 6), FilterAtCaret(kind: .rooms, start: 5, end: 6, typed: ""))
        XCTAssertEqual(LocalSearch.filterAtCaret("user:@adam late", caret: 8), FilterAtCaret(kind: .users, start: 5, end: 10, typed: "ad"),
                       "mid-value, typed is what is before the caret and the value runs on to the next space")
    }

    func testFindsNothingInAWordPastASpaceOrInAQuotedName() {
        XCTAssertNil(LocalSearch.filterAtCaret("deploy", caret: 6))
        XCTAssertNil(LocalSearch.filterAtCaret("user:@ada ", caret: 10))
        XCTAssertNil(LocalSearch.filterAtCaret("nouser:ad", caret: 9))
        XCTAssertNil(LocalSearch.filterAtCaret("user:\"Ada", caret: 9))
        XCTAssertNil(LocalSearch.filterAtCaret("user:ad\n", caret: 8))
    }

    func testPutsAValueInWithASpaceAfterItAndTheCaretAfterThat() {
        let at = LocalSearch.filterAtCaret("deploy user:@ad late", caret: 15)!
        XCTAssertEqual(LocalSearch.withFilterValue("deploy user:@ad late", at: at, value: "@ada").query, "deploy user:@ada late")
        XCTAssertEqual(LocalSearch.withFilterValue("deploy user:@ad late", at: at, value: "@ada").caret, 17)
        let end = LocalSearch.filterAtCaret("room:ge", caret: 7)!
        XCTAssertEqual(LocalSearch.withFilterValue("room:ge", at: end, value: "#general").query, "room:#general ")
        XCTAssertEqual(LocalSearch.withFilterValue("room:ge", at: end, value: "#general").caret, 14)
    }

    func testCountsTheCaretInUTF16Units() {
        let at = LocalSearch.filterAtCaret("😀 user:@ad", caret: 11)
        XCTAssertEqual(at, FilterAtCaret(kind: .users, start: 8, end: 11, typed: "ad"))
        XCTAssertEqual(LocalSearch.withFilterValue("😀 user:@ad", at: at!, value: "@ada").query, "😀 user:@ada ")
        XCTAssertEqual(LocalSearch.withFilterValue("😀 user:@ad", at: at!, value: "@ada").caret, 13)
    }

    // MARK: searchPeople

    func testListsSomeoneNamedExactlyFirstThenByPrefixThenHoldingIt() {
        let people: [(id: String, name: String?)] = [("adam", "Adam"), ("ada", "Ada Lovelace"), ("zoe", "Zoë Cadabra"), ("bob", nil)]
        func search(_ typed: String, limit: Int = 8) -> [String] {
            LocalSearch.searchPeople(people, typed: typed, limit: limit, id: \.id, name: \.name).map(\.id)
        }
        XCTAssertEqual(search("ada"), ["ada", "adam", "zoe"])
        XCTAssertEqual(search("zoe"), ["zoe"])
        XCTAssertEqual(search(""), ["ada", "adam", "bob", "zoe"])
        XCTAssertEqual(search("a", limit: 2), ["ada", "adam"])
    }
}
