@testable import ApronKit
import Foundation
import Network
import Synchronization
import XCTest

/// Push kind `relay` (§4.9) against the real Rust server: Ladle registers a relay endpoint, goes
/// away, and a mention arrives at the relay as the §4.9.3 payload with the relay's bearer token.
@MainActor
final class PushIntegrationTests: XCTestCase {
    private var server: Aprond?
    private var relay: LoopbackRelay?
    private var sessions: [ServerSession] = []

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        server?.stop()
        relay?.stop()
    }

    private func session(_ server: Aprond) async throws -> ServerSession {
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let session = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(session)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        return session
    }

    func testAMentionWhileAwayReachesTheRelay() async throws {
        let relay = try await LoopbackRelay.start()
        self.relay = relay
        let server = try await Aprond.start(["--push.allow-insecure", "--push.hosts", "127.0.0.1", "--push.delay", "0s"])
        self.server = server

        let ada = try await session(server)
        _ = try await ada.signIn(.emailProposal(address: "ada@example.com"))
        _ = try await ada.signIn(.emailCode(try await server.emailCode(for: "ada@example.com")))
        try await waitFor("the room list") { ada.joinedRoomIDs.contains("general") }
        XCTAssertTrue(ada.offersRelayPush, "aprond offers kind relay")
        let adaID = try XCTUnwrap(ada.you?.userID)

        let endpoint = RelayEndpoint(url: URL(string: "http://127.0.0.1:\(relay.port)/p/ada-phone")!, token: "relay-secret")
        await ada.registerPush(endpoint, pushID: "t65S5XBst9bSDpjJ", scopes: [.mentions])
        XCTAssertEqual(ada.push, .on(url: endpoint.url, wake: ["mentions"]))
        await ada.stop()

        let bram = try await session(server)
        // A guest's message wakes no one (aprond's wake rules), so Bram has an account.
        _ = try await bram.signIn(.emailProposal(address: "bram@example.com"))
        _ = try await bram.signIn(.emailCode(try await server.emailCode(for: "bram@example.com")))
        try await waitFor("bram's room list") { bram.joinedRoomIDs.contains("general") }
        bram.post("@\(adaID) the build is green", in: "general", mentions: [adaID])

        let delivered: LoopbackRelay.Request
        do { delivered = try await relay.next(timeout: .seconds(10)) } catch { return XCTFail("\(error)\n\(server.output)") }
        XCTAssertEqual(delivered.path, "/p/ada-phone")
        XCTAssertEqual(delivered.authorization, "Bearer relay-secret")
        XCTAssertEqual(delivered.contentType, "application/json")
        let payload = try JSONValue(parsing: delivered.body)
        XCTAssertEqual(payload["push_id"], "t65S5XBst9bSDpjJ")
        XCTAssertEqual(payload["message"]?["room_id"], "general")
        XCTAssertEqual(payload["message"]?["from"]?["user_id"], bram.you.map { .string($0.userID) })
        XCTAssertEqual(payload["message"]?["body"]?["text"], .string("@\(adaID) the build is green"))
        XCTAssertNotNil(LogID(payload["message"]?["message_id"]))

        // What a relay hands APNs reads back as that message, on the account with that push_id.
        let settings = NotificationSettings(makePushID: { "t65S5XBst9bSDpjJ" })
        _ = settings.pushID(of: NotificationSettings.account(server: ada.record.id, userID: adaID, guest: false))
        let place = settings.place(ofPush: ["apron": String(decoding: delivered.body, as: UTF8.self)])
        XCTAssertEqual(place?.server, ada.record.id)
        XCTAssertEqual(place?.roomID, "general")
    }

    func testUnregisterIsAccepted() async throws {
        let server = try await Aprond.start(["--push.allow-insecure", "--push.hosts", "127.0.0.1"])
        self.server = server
        let ada = try await session(server)
        _ = try await ada.signIn(.emailProposal(address: "ada@example.com"))
        _ = try await ada.signIn(.emailCode(try await server.emailCode(for: "ada@example.com")))
        await ada.registerPush(RelayEndpoint(url: URL(string: "http://127.0.0.1:9/p/x")!), pushID: "p1", scopes: NotifyScope.defaults)
        XCTAssertTrue(ada.push.isOn, "\(ada.push)")
        await ada.unregisterPush()
        XCTAssertEqual(ada.push, .off)
        await ada.registerPush(RelayEndpoint(url: URL(string: "http://relay.invalid/p/x")!), pushID: "p1", scopes: NotifyScope.defaults)
        guard case .refused = ada.push else { return XCTFail("a host --push.hosts leaves out is refused: \(ada.push)") }
    }
}

/// A relay on a loopback port that answers every POST with 201 and keeps what came.
final class LoopbackRelay: @unchecked Sendable {
    struct Request: Sendable {
        var path: String
        var authorization: String?
        var contentType: String?
        var body: Data
    }

    let port: Int
    private let listener: NWListener
    private let received = Mutex<[Request]>([])

    private init(listener: NWListener, port: Int) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> LoopbackRelay {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = AsyncStream<Int> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(Int(listener.port?.rawValue ?? 0)); continuation.finish() }
            }
        }
        let holder = Mutex<LoopbackRelay?>(nil)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            holder.withLock { $0 }?.read(connection, buffered: Data())
        }
        listener.start(queue: .global())
        var port = 0
        for await value in ready { port = value }
        let relay = LoopbackRelay(listener: listener, port: port)
        holder.withLock { $0 = relay }
        return relay
    }

    func stop() { listener.cancel() }

    func next(timeout: Duration) async throws -> Request {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let first = received.withLock({ $0.first }) { return first }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Aprond.Failure(message: "nothing reached the relay")
    }

    private func read(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, _ in
            let all = buffered + (data ?? Data())
            if let request = Self.parse(all) {
                received.withLock { $0.append(request) }
                let reply = Data("HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            } else if !done {
                read(connection, buffered: all)
            }
        }
    }

    /// A whole HTTP/1.1 request with a `Content-Length` body, or nil while more is to come.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        let path = head.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return Request(path: path, authorization: headers["authorization"], contentType: headers["content-type"], body: Data(body.prefix(length)))
    }
}
