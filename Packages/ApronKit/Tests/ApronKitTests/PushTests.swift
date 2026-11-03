@testable import ApronKit
import Foundation
import XCTest

/// Push (§4.9) as Ladle registers it through a relay, and the pushes it reads back.
@MainActor
final class PushTests: ScriptedSessionCase {
    let endpoint = RelayEndpoint(url: URL(string: "https://relay.example/p/abc")!, token: "secret")

    func queuePushServer(push: JSONValue) -> FakeTransport {
        let transport = FakeTransport()
        transports.queued.withLock { $0.append(transport) }
        let params: JSONValue = ["apron": 10, "auth": ["token"], "capabilities": ["history", "rooms", "status"], "push": push]
        Task { await transport.deliver(["method": "server", "params": params]) }
        return transport
    }

    func signInWithToken(_ transport: FakeTransport) async throws {
        session.start()
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.token("t")) }
        _ = await sent(transport, count: 2)
        await transport.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await transport.deliver(["id": "c2", "result": ["joined": []]])
        _ = try await signIn.value
    }

    func testRegisterAndUnregisterAsTheSpecSays() async throws {
        let socket = queuePushServer(push: ["relay": [:], "webpush": ["key": "BNcR"], "wake": ["mentions", "replies", "private", "badge"]])
        try await signInWithToken(socket)
        XCTAssertTrue(session.offersRelayPush)
        XCTAssertNil(session.pushBlocker(inBuild: true, relay: URL(string: "https://relay.example"), endpoint: endpoint))
        let register = Task { await session.registerPush(endpoint, pushID: "t65S5XBst9bSDpjJ", scopes: [.mentions, .private, .joined]) }
        let frames = await sent(socket, count: 3)
        XCTAssertEqual(try JSONValue(parsing: frames[2]), [
            "method": "push_register", "id": "c3",
            "params": ["kind": "relay", "url": "https://relay.example/p/abc", "token": "secret", "push_id": "t65S5XBst9bSDpjJ",
                       "wake": ["mentions", "private"]],
        ])
        await socket.deliver(["id": "c3", "result": [:]])
        await register.value
        XCTAssertEqual(session.push, .on(url: URL(string: "https://relay.example/p/abc")!, wake: ["mentions", "private"]))
        let unregister = Task { await session.unregisterPush() }
        let after = await sent(socket, count: 4)
        XCTAssertEqual(try JSONValue(parsing: after[3]), ["method": "push_unregister", "id": "c4", "params": ["url": "https://relay.example/p/abc"]])
        await socket.deliver(["id": "c4", "result": [:]])
        await unregister.value
        XCTAssertEqual(session.push, .off)
    }

    func testARefusalShowsTheServersWords() async throws {
        let socket = queuePushServer(push: ["relay": [:]])
        try await signInWithToken(socket)
        let register = Task { await session.registerPush(RelayEndpoint(url: URL(string: "https://relay.example/p/abc")!), pushID: "p", scopes: [.joined]) }
        let frames = await sent(socket, count: 3)
        XCTAssertEqual(try JSONValue(parsing: frames[2])["params"], ["kind": "relay", "url": "https://relay.example/p/abc", "push_id": "p"])
        await socket.deliver(["id": "c3", "error": ["code": -32602, "message": "That push endpoint isn't allowed here."]])
        await register.value
        XCTAssertEqual(session.push, .refused("That push endpoint isn't allowed here."))
    }

    func testWhyPushCantAlertWhileClosed() async throws {
        let socket = queuePushServer(push: ["webpush": ["key": "BNcR"]])
        try await signInWithToken(socket)
        let relay = URL(string: "https://relay.example")
        XCTAssertEqual(session.pushBlocker(inBuild: false, relay: relay, endpoint: endpoint), .notInThisBuild)
        XCTAssertEqual(session.pushBlocker(inBuild: true, relay: relay, endpoint: endpoint), .serverOffersNone)
    }

    func testTheRelaysEndpoint() throws {
        let request = RelayEndpoint.request(relay: URL(string: "https://relay.example/")!, deviceToken: Data([0x0a, 0xff, 0x00]),
                                            environment: "development", topic: "app.ladle.ios")
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/v1/register")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(try JSONValue(parsing: request.httpBody!), ["device_token": "0aff00", "environment": "development", "topic": "app.ladle.ios"])
        XCTAssertEqual(RelayEndpoint(response: Data(#"{"url":"https://relay.example/p/x","token":"k"}"#.utf8)),
                       RelayEndpoint(url: URL(string: "https://relay.example/p/x")!, token: "k"))
        XCTAssertNil(RelayEndpoint(response: Data(#"{"url":"http://relay.example/p/x"}"#.utf8)))
    }

    func testATappedPushOpensItsMessageOnItsAccountsServer() {
        let settings = NotificationSettings(makePushID: { "t65S5XBst9bSDpjJ" })
        _ = settings.pushID(of: "00000000-0000-0000-0000-000000000009\nada")
        let payload = #"{"push_id":"t65S5XBst9bSDpjJ","unread":2,"message":{"message_id":"1724803200042","room_id":"general","from":{"user_id":"alice"}}}"#
        XCTAssertEqual(settings.place(ofPush: ["apron": payload]),
                       ReminderKey(server: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!, roomID: "general", messageID: LogID("1724803200042")!))
        XCTAssertNil(settings.place(ofPush: ["apron": #"{"push_id":"someone-else","message":{"message_id":"1","room_id":"general"}}"#]))
        XCTAssertNil(settings.place(ofPush: ["apron": #"{"push_id":"t65S5XBst9bSDpjJ","unread":0}"#]))
    }
}
