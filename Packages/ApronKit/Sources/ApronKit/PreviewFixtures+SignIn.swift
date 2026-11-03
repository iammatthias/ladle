import Foundation

/// A server that signs in every way (passkeys, email, its own page, a token, guests), for the
/// sign-in screenshots, in a store of its own so the two-server world stays as it is: one
/// account signed in with a token alone (the "add a sign-in" nudge), one passkey account whose
/// saved token the server refused (held for a tap), and one not signed in.
extension PreviewFixtures {
    public static let ownerID = UUID(uuidString: "6C61646C-0000-4000-8000-000000000011")!
    public static let heldID = UUID(uuidString: "6C61646C-0000-4000-8000-000000000012")!
    public static let freshID = UUID(uuidString: "6C61646C-0000-4000-8000-000000000013")!
    /// The domain the renderer's passkey list holds (LadleShots' `LadlePasskeyDomains`).
    public static let ownerURL = URL(string: "wss://owner.example/ws")!

    private static let ownerGreeting: JSONValue = [
        "apron": 9, "auth": ["webauthn", "email", "external", "token", "guest"], "agent": "aprond/0.9",
        "title": "Owner", "capabilities": ["history", "rooms", "status", "ext", "ext:bio"],
        "welcome": "Guests can read along. Create a passkey to post.",
    ]

    private static var owner: PreviewServer.Script {
        PreviewServer.Script(greeting: ownerGreeting, you: ["user_id": "sam", "name": "Sam"],
                             roomList: ["joined": [["room_id": "general", "log_id": "1", "title": "general", "latest_log_id": "1", "history_log_id": "1"]]],
                             histories: [:], readCursors: [:])
    }

    @MainActor
    public static func makeSignInStore() async -> SessionStore {
        let tokens = InMemoryTokenStore()
        let environment = ServerSession.Environment(
            makeTransport: { _ in PreviewServer(script: owner) },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            jitter: { 1 }
        )
        let store = SessionStore(serverStore: nil, tokens: tokens, environment: environment)
        try? tokens.setToken("preview", for: ownerID)
        try? tokens.setToken(PreviewServer.expiredToken, for: heldID)
        store.add(ServerRecord(id: ownerID, url: ownerURL, label: "Owner", account: .init(userID: "sam", name: "Sam", scheme: "token")))
        store.add(ServerRecord(id: heldID, url: ownerURL, label: "Owner", account: .init(userID: "sam", name: "Sam", scheme: "webauthn")))
        store.add(ServerRecord(id: freshID, url: ownerURL, label: "Owner"))
        for id in [ownerID, heldID, freshID] {
            guard let session = store.session(for: id) else { continue }
            await until { session.status == (id == ownerID ? .signedIn : .signedOut) }
        }
        return store
    }

    public static let newerID = UUID(uuidString: "6C61646C-0000-4000-8000-000000000014")!

    /// A server speaking a protocol version newer than Ladle's, for the version warning's shots.
    @MainActor
    public static func makeNewerServerStore() async -> SessionStore {
        let tokens = InMemoryTokenStore()
        let greeting: JSONValue = ["apron": 11, "auth": ["token", "guest"], "agent": "aprond/0.11", "title": "Next", "capabilities": ["history", "rooms"]]
        let script = PreviewServer.Script(greeting: greeting, you: ["user_id": "sam", "name": "Sam"],
                                          roomList: ["joined": [["room_id": "general", "log_id": "1", "title": "general", "latest_log_id": "1", "history_log_id": "1"]]],
                                          histories: [:], readCursors: [:])
        let environment = ServerSession.Environment(
            makeTransport: { _ in PreviewServer(script: script) },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            jitter: { 1 }
        )
        let store = SessionStore(serverStore: nil, tokens: tokens, environment: environment)
        try? tokens.setToken("preview", for: newerID)
        store.add(ServerRecord(id: newerID, url: URL(string: "wss://next.example/ws")!, label: "Next", account: .init(userID: "sam", name: "Sam", scheme: "token")))
        if let session = store.session(for: newerID) { await until { session.status == .signedIn } }
        return store
    }

    public static let startingID = UUID(uuidString: "6C61646C-0000-4000-8000-000000000015")!

    /// A server that never answers, so its session stays connecting with nothing kept: the
    /// placeholders a first visit shows (apron-web #173).
    @MainActor
    public static func makeStartingStore() -> SessionStore {
        let environment = ServerSession.Environment(
            makeTransport: { _ in SilentTransport() },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            jitter: { 1 }
        )
        let store = SessionStore(serverStore: nil, tokens: InMemoryTokenStore(), environment: environment)
        store.add(ServerRecord(id: startingID, url: URL(string: "wss://slow.example/ws")!, label: "Slow"))
        return store
    }
}

/// A transport whose connection never opens.
private struct SilentTransport: FrameTransport {
    func connect() async throws { try await Task.sleep(for: .seconds(3600)) }
    func send(_ text: String) async throws {}
    func receive() async throws -> String { throw FrameTransportError.closed }
    func close() async {}
}
