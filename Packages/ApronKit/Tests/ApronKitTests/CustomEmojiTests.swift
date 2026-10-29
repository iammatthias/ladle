@testable import ApronKit
import Foundation
import Synchronization
import XCTest

final class CustomEmojiTests: XCTestCase {
    private func fixture(_ name: String) throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/ext-emoji"))
        return try JSONValue(parsing: Data(contentsOf: url))
    }

    private let demoURL = URL(string: "wss://server.apron.chat/")!

    func testTheDemosRecordedCatalogDecodes() throws {
        let server = try XCTUnwrap(ServerInfo(params: try fixture("demo-server")["params"]))
        XCTAssertEqual(server.emojiCatalogURL?.absoluteString,
                       "https://media.apron.chat/e/c/9a14c45fbb303b8da5df0558a367dc98b1f0a4ebd9a10644e9442bd1a6418c46.json")
        XCTAssertEqual(server.title, "Apron Demo")
        XCTAssertEqual(MediaLimits.verdict(for: "image/png", in: MediaLimits(server: server)?.emoji), .allowed(.init(maxBytes: 262_144)))

        let catalog = EmojiCatalog(json: try fixture("demo-catalog"), policy: MediaPolicy(serverURL: demoURL, server: server))
        XCTAssertEqual(catalog.emoji, [":apron:": CustomEmoji(
            key: ":apron:", url: URL(string: "https://media.apron.chat/e/nrIp9696F6rvBbltXXvS6A")!, alt: nil, aspectRatio: 1,
            staticURL: nil, category: nil, tags: [], hidden: false)])
        XCTAssertEqual(catalog[":apron:"]?.label, ":apron:", "the key without alt")
    }

    func testEntriesDecodeFieldByField() {
        let policy = MediaPolicy(serverURL: URL(string: "wss://chat.example/ws")!, server: nil)
        let catalog = EmojiCatalog(json: [
            ":partyparrot:": ["url": "https://chat.example/e/p", "static_url": "https://chat.example/e/p/still",
                              "category": " Parrots ", "tags": ["party", 3, ""], "alt": "Party \u{202E}parrot"],
            ":shipit:": ["url": "https://chat.example/e/s", "width": 64, "height": 32, "alt": "Squirrel in a hat"],
            ":wide:": ["url": "https://chat.example/e/w", "width": 64],
            ":old:": ["url": "https://chat.example/e/o", "hidden": true, "static_url": "javascript:alert(1)"],
            ":plain-http:": ["url": "http://cdn.example/e"],
            ":no-url:": ["alt": "nothing to show"],
            "nocolons": ["url": "https://chat.example/e/n"],
            ":bad key:": ["url": "https://chat.example/e/b"],
            ":list:": ["https://chat.example/e/l"],
        ], policy: policy)
        XCTAssertEqual(Set(catalog.emoji.keys), [":partyparrot:", ":shipit:", ":wide:", ":old:"])
        let parrot = catalog[":partyparrot:"]
        XCTAssertEqual(parrot?.category, "Parrots")
        XCTAssertEqual(parrot?.tags, ["party"])
        XCTAssertEqual(parrot?.alt, "Party parrot", "no overrides in shown text")
        XCTAssertEqual(parrot?.imageURL(reduceMotion: true).absoluteString, "https://chat.example/e/p/still")
        XCTAssertEqual(parrot?.imageURL(reduceMotion: false).absoluteString, "https://chat.example/e/p")
        XCTAssertEqual(catalog[":shipit:"]?.aspectRatio, 2)
        XCTAssertNil(catalog[":wide:"]?.aspectRatio, "square without both sides")
        XCTAssertEqual(catalog[":old:"]?.staticURL, nil)
        XCTAssertEqual(catalog[":old:"]?.imageURL(reduceMotion: true).absoluteString, "https://chat.example/e/o")

        XCTAssertEqual(catalog.offered.map(\.key), [":shipit:", ":wide:", ":partyparrot:"], "no category first, hidden left out")
        XCTAssertEqual(catalog.search(":part").map(\.key), [":partyparrot:"])
        XCTAssertEqual(catalog.search("SQUIRREL").map(\.key), [":shipit:"], "by alt")
        XCTAssertEqual(catalog.search("party").map(\.key), [":partyparrot:"])
        XCTAssertEqual(catalog.search("old"), [], "hidden ones are not offered")
        XCTAssertEqual(catalog.search("i").map(\.key), [":shipit:", ":wide:"], "a name match before an alt match")
    }

    func testTheCatalogURLMustBeOneClientsFetch() {
        func url(_ value: String, capabilities: [JSONValue] = ["ext:emoji"]) -> String? {
            ServerInfo(params: ["apron": 9, "auth": [], "capabilities": .array(capabilities),
                                "ext": ["emoji": ["catalog_url": .string(value)]]])?.emojiCatalogURL?.absoluteString
        }
        XCTAssertEqual(url("https://chat.example/e/c.json"), "https://chat.example/e/c.json")
        XCTAssertEqual(url("http://localhost:8080/c.json"), "http://localhost:8080/c.json")
        XCTAssertEqual(url("data:application/json;base64,e30="), "data:application/json;base64,e30=")
        XCTAssertNil(url("http://chat.example/c.json"))
        XCTAssertNil(url("data:text/html,<b>"))
        XCTAssertNil(url("javascript:alert(1)"))
        XCTAssertNil(url("https://chat.example/e/c.json", capabilities: []), "only while the server lists ext:emoji")
    }

    func testAnInlineCatalogIsReadWithoutTheNetwork() async throws {
        let inline = #"{":a:": {"url": "https://chat.example/e/a"}}"#
        for text in ["data:application/json;base64," + Data(inline.utf8).base64EncodedString(),
                     "data:application/json," + inline.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!] {
            let data = try await EmojiCatalogFetch.live(try XCTUnwrap(URL(string: text)))
            XCTAssertEqual(try JSONValue(parsing: data)[":a:"]?["url"], "https://chat.example/e/a", text)
        }
    }

    func testKeysAreFoundLeftToRight() {
        func keys(_ text: String, _ known: Set<String> = [":a:", ":b:", ":partyparrot:"]) -> [String] {
            EmojiKeys.ranges(in: text, known: known.contains).map { String(text[$0]) }
        }
        XCTAssertEqual(keys(":a::b:"), [":a:", ":b:"], "adjacent keys")
        XCTAssertEqual(keys("12:30:partyparrot:"), [":partyparrot:"])
        XCTAssertEqual(keys("at 9:a:b: then"), [":a:"], "an unknown span moves on to the next colon")
        XCTAssertEqual(keys(":unknown: :a"), [])
        XCTAssertEqual(keys("::a:"), [":a:"])
        XCTAssertEqual(keys(":A:"), [], "keys are case-sensitive")
        XCTAssertTrue(EmojiKeys.mayHaveKeys("hi :anything:"))
        XCTAssertFalse(EmojiKeys.mayHaveKeys("12:30 and 13:45"))
    }

    func testKeysInTextAreMarkedOutsideCodeAndLinks() {
        let policy = MediaPolicy(serverURL: URL(string: "wss://chat.example/ws")!, server: nil)
        let catalog = EmojiCatalog(json: [":apron:": ["url": "https://chat.example/e/a"]], policy: policy)
        let text = MessageText.attributed(["text": "Shipped :apron: `:apron:` [:apron:](https://x.example) :nope:", "format": "markdown"], emoji: catalog)
        let marked = text.runs.compactMap { run in run[CustomEmojiKey.self].map { _ in String(text[run.range].characters) } }
        XCTAssertEqual(marked, [":apron:"])
        XCTAssertNil(MessageText.attributed(["text": ":apron:"]).runs.first?[CustomEmojiKey.self], "nothing without a catalog")
        XCTAssertEqual(MessageText.markdown("Welcome :apron:", emoji: catalog).runs.compactMap { $0[CustomEmojiKey.self] }, [":apron:"])
    }

    @MainActor
    func testTheCatalogIsFetchedOncePerURLAndAgainOnlyWhenItChanges() async throws {
        let fetched = Mutex<[String]>([])
        let failing = Mutex(true)
        let socket = FakeTransport()
        let environment = ServerSession.Environment(
            makeTransport: { _ in socket },
            fetchEmojiCatalog: { url in
                fetched.withLock { $0.append(url.lastPathComponent) }
                if url.lastPathComponent == "bad.json", failing.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
                return Data(#"{":apron:": {"url": "https://chat.example/e/\#(url.lastPathComponent)"}}"#.utf8)
            }
        )
        let record = ServerRecord(url: URL(string: "wss://chat.example/ws")!)
        let session = ServerSession(record: record, tokens: InMemoryTokenStore(), positions: InMemoryReadPositionStore(), environment: environment)
        session.start()
        func greet(_ catalog: String) async {
            await socket.deliver(["method": "server", "params": ["apron": 9, "auth": ["guest"], "capabilities": ["ext:emoji"],
                                                                 "ext": ["emoji": ["catalog_url": .string("https://chat.example/e/\(catalog)")]]]])
            while session.server?.emojiCatalogURL?.lastPathComponent != catalog { await Task.yield() }
        }
        await greet("one.json")
        XCTAssertNil(session.emojiCatalog, "nothing until something needs it")
        await session.loadEmojiCatalog()
        await session.loadEmojiCatalog()
        XCTAssertEqual(session.emojiCatalog?[":apron:"]?.url.lastPathComponent, "one.json")

        await greet("bad.json")
        XCTAssertNil(session.emojiCatalog, "keys show as without the extension until the new catalog arrives")
        await session.loadEmojiCatalog()
        failing.withLock { $0 = false }
        await session.loadEmojiCatalog()
        XCTAssertNil(session.emojiCatalog, "a failed fetch is not tried again for the same URL")

        await greet("one.json")
        await session.loadEmojiCatalog()
        XCTAssertEqual(session.emojiCatalog?[":apron:"]?.url.lastPathComponent, "one.json", "kept by URL")
        XCTAssertEqual(fetched.withLock { $0 }, ["one.json", "bad.json"])
        await session.stop()
    }
}
