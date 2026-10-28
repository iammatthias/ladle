import XCTest
@testable import ApronKit

final class ServerRecordTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        // A space, as in iOS's "Application Support", so a percent-encoded path would miss the file.
        directory = FileManager.default.temporaryDirectory.appending(path: "ApronKit Tests-\(UUID().uuidString)")
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

    func testReadPositionsPersistForwardOnlyPerServerAndUser() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "apron-positions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let store = FileReadPositionStore(directory: directory)
        XCTAssertEqual(store.positions(server: server, user: "ada"), [:])
        store.advance("general", to: LogID("200")!, server: server, user: "ada")
        store.advance("general", to: LogID("150")!, server: server, user: "ada")
        store.advance("design", to: LogID("90")!, server: server, user: "ada")
        store.advance("general", to: LogID("300")!, server: other, user: "ada")
        store.advance("general", to: LogID("10")!, server: server, user: "bob")

        let reopened = FileReadPositionStore(directory: directory)
        XCTAssertEqual(reopened.positions(server: server, user: "ada"), ["general": LogID("200")!, "design": LogID("90")!])
        XCTAssertEqual(reopened.positions(server: other, user: "ada"), ["general": LogID("300")!])
        XCTAssertEqual(reopened.positions(server: server, user: "bob"), ["general": LogID("10")!])
        XCTAssertEqual(String(decoding: try Data(contentsOf: reopened.fileURL), as: UTF8.self), """
        {
          "00000000-0000-0000-0000-00000000000A" : {
            "ada" : {
              "design" : "90",
              "general" : "200"
            },
            "bob" : {
              "general" : "10"
            }
          },
          "00000000-0000-0000-0000-00000000000B" : {
            "ada" : {
              "general" : "300"
            }
          }
        }
        """)

        try Data("not json".utf8).write(to: reopened.fileURL)
        XCTAssertEqual(reopened.positions(server: server, user: "ada"), [:], "a damaged file is empty")
        reopened.advance("general", to: LogID("5")!, server: server, user: "ada")
        XCTAssertEqual(FileReadPositionStore(directory: directory).positions(server: server, user: "ada"), ["general": LogID("5")!])
    }
}
