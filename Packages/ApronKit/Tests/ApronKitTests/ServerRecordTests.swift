import XCTest
@testable import ApronKit

final class ServerRecordTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ApronKitTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultsDeriveFromTheURL() throws {
        let record = ServerRecord(url: URL(string: "wss://chat.example.org/ws")!)
        XCTAssertEqual(record.label, "chat.example.org")
        XCTAssertEqual(record.origin, "https://chat.example.org")
        XCTAssertNil(record.rpID)
        XCTAssertNil(record.account)
        XCTAssertEqual(ServerRecord.defaultOrigin(for: URL(string: "ws://localhost:8080/ws")!), "https://localhost:8080")
    }

    func testSaveAndLoadRoundTripThroughTheStore() throws {
        let store = ServerStore(directory: directory)
        XCTAssertEqual(try store.load(), [])
        let id = UUID(uuidString: "7D3F4A52-0A3E-4C1B-9D55-1F2E3D4C5B6A")!
        let records = [
            ServerRecord(id: id, url: URL(string: "wss://chat.example.org/ws")!, label: "Example", origin: "https://web.example.org",
                         rpID: "chat.example.org", account: .init(userID: "ada", name: "Ada", scheme: "token")),
            ServerRecord(url: URL(string: "ws://localhost:8080/ws")!),
        ]
        try store.save(records)
        XCTAssertEqual(try store.load(), records)
        XCTAssertEqual(store.fileURL.lastPathComponent, "servers.json")
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#""userID" : "ada""#), text)
        XCTAssertFalse(text.contains("token-"), "no secrets in servers.json")
    }

    func testOlderFilesWithoutLaterFieldsStillLoad() throws {
        let legacy = #"[{"id":"7D3F4A52-0A3E-4C1B-9D55-1F2E3D4C5B6A","url":"wss://chat.example.org/ws"}]"#
        let records = try JSONDecoder().decode([ServerRecord].self, from: Data(legacy.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id.uuidString, "7D3F4A52-0A3E-4C1B-9D55-1F2E3D4C5B6A")
        XCTAssertEqual(records[0].label, "chat.example.org")
        XCTAssertEqual(records[0].origin, "https://chat.example.org")
        XCTAssertNil(records[0].rpID)
        XCTAssertNil(records[0].account)

        let withUnknownKey = #"[{"id":"7D3F4A52-0A3E-4C1B-9D55-1F2E3D4C5B6A","url":"wss://x.example/ws","label":"X","futureField":1}]"#
        XCTAssertEqual(try JSONDecoder().decode([ServerRecord].self, from: Data(withUnknownKey.utf8))[0].label, "X")
    }

    func testTokenStoreKeysByServer() throws {
        let tokens = InMemoryTokenStore()
        let a = UUID(), b = UUID()
        XCTAssertNil(try tokens.token(for: a))
        try tokens.setToken("token-a", for: a)
        try tokens.setToken("token-b", for: b)
        XCTAssertEqual(try tokens.token(for: a), "token-a")
        XCTAssertEqual(try tokens.token(for: b), "token-b")
        try tokens.setToken(nil, for: a)
        XCTAssertNil(try tokens.token(for: a))
        XCTAssertEqual(try tokens.token(for: b), "token-b")
    }
}
