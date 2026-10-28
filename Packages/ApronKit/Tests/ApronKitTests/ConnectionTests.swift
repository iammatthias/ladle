import Synchronization
import XCTest
@testable import ApronKit

/// An in-memory transport: the test plays the server, feeding frames in and reading frames out.
actor FakeTransport: FrameTransport {
    private var inbox: [String] = []
    private var inboxClosed = false
    private var reader: CheckedContinuation<String?, Never>?
    nonisolated let sent: AsyncStream<String>
    private let sentSink: AsyncStream<String>.Continuation
    private(set) var connectCalls = 0
    private(set) var closed = false

    init() {
        (sent, sentSink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
    }

    func connect() async throws { connectCalls += 1 }

    func send(_ text: String) async throws {
        if closed { throw FrameTransportError.closed }
        sentSink.yield(text)
    }

    func receive() async throws -> String {
        if !inbox.isEmpty { return inbox.removeFirst() }
        if inboxClosed { throw FrameTransportError.closed }
        let next = await withCheckedContinuation { reader = $0 }
        guard let next else { throw FrameTransportError.closed }
        return next
    }

    func close() async {
        closed = true
        dropFromServer()
    }

    /// The server sends a frame.
    func deliver(_ frame: JSONValue) { deliver(raw: frame.serialized()) }

    func deliver(raw text: String) {
        if let reader { self.reader = nil; reader.resume(returning: text) } else { inbox.append(text) }
    }

    /// The server closes the socket.
    func dropFromServer() {
        inboxClosed = true
        reader?.resume(returning: nil)
        reader = nil
    }
}

final class ConnectionTests: XCTestCase {
    private let greeting: JSONValue = ["method": "server", "params": ["apron": 9, "auth": ["guest", "token"], "capabilities": ["rooms", "history"], "welcome": "Hi"]]

    private func makeConnection() -> (Connection, FakeTransport) {
        let transport = FakeTransport()
        let counter = Mutex(0)
        let connection = Connection(transport: transport, makeRequestID: {
            counter.withLock { $0 += 1; return "c\($0)" }
        })
        return (connection, transport)
    }

    func testConnectReturnsTheTypedServerFrame() async throws {
        let (connection, transport) = makeConnection()
        await transport.deliver(greeting)
        let server = try await connection.connect()
        XCTAssertEqual(server.apron, 9)
        XCTAssertEqual(server.auth, ["guest", "token"])
        XCTAssertEqual(server.capabilities, ["rooms", "history"])
        XCTAssertEqual(server.welcome, "Hi")
        XCTAssertNil(server.ping)
        let kept = await connection.server
        XCTAssertEqual(kept, server)
        let pingInterval = await connection.pingInterval
        XCTAssertNil(pingInterval)
        let calls = await transport.connectCalls
        XCTAssertEqual(calls, 1)
    }

    func testRequestSendsTheExactFrameAndMatchesTheReplyByID() async throws {
        let (connection, transport) = makeConnection()
        await transport.deliver(greeting)
        _ = try await connection.connect()
        var outgoing = transport.sent.makeAsyncIterator()

        let auth = Task { try await connection.request("auth", params: ["scheme": "guest", "name": "Ada"]) }
        let sentText = await outgoing.next()
        XCTAssertEqual(sentText, #"{"id":"c1","method":"auth","params":{"name":"Ada","scheme":"guest"}}"#)

        await transport.deliver(["id": "unrelated", "result": ["ignored": true]])
        await transport.deliver(["id": "c1", "result": ["you": ["user_id": "guest_7", "name": "Ada"]], "jsonrpc": "2.0"])
        let result = try await auth.value
        XCTAssertEqual(result, ["you": ["user_id": "guest_7", "name": "Ada"]])

        let message = Task { try await connection.request("message", params: ["body": ["text": "hi"]]) }
        let second = await outgoing.next()
        XCTAssertEqual(second, #"{"id":"c2","method":"message","params":{"body":{"text":"hi"}}}"#)
        await transport.deliver(["id": "c2", "result": ["message_id": "1724803200042"]])
        let posted = try await message.value
        XCTAssertEqual(posted["message_id"], "1724803200042")
    }

    func testPipelinedRequestsReachTheWireInCallOrderAndRepliesResolveOutOfOrder() async throws {
        let (connection, transport) = makeConnection()
        await transport.deliver(greeting)
        _ = try await connection.connect()
        var outgoing = transport.sent.makeAsyncIterator()
        let auth = try await connection.send("auth", params: ["scheme": "guest"])
        let rooms = try await connection.send("room_list", params: ["filter": "joined"])
        let history = try await connection.send("history", params: ["room_id": "general"])
        var sent: [String] = []
        for _ in 0 ..< 3 { sent.append(await outgoing.next() ?? "") }
        XCTAssertEqual(sent, [
            #"{"id":"c1","method":"auth","params":{"scheme":"guest"}}"#,
            #"{"id":"c2","method":"room_list","params":{"filter":"joined"}}"#,
            #"{"id":"c3","method":"history","params":{"room_id":"general"}}"#,
        ])
        await transport.deliver(["id": "c3", "result": ["messages": []]])
        await transport.deliver(["id": "c1", "result": ["you": ["user_id": "guest_1"]]])
        let roomsValue = Task { try await rooms.value }
        await transport.deliver(["id": "c2", "error": ["code": -32001, "message": "Denied"]])
        let historyResult = try await history.value
        let authResult = try await auth.value
        XCTAssertEqual(historyResult, ["messages": []])
        XCTAssertEqual(authResult, ["you": ["user_id": "guest_1"]])
        do {
            _ = try await roomsValue.value
            XCTFail("expected denied")
        } catch let error as RPCError {
            XCTAssertEqual(error.code, RPCError.Code.denied)
        }
        await connection.close()
    }

    func testErrorReplyThrowsTheRPCError() async throws {
        let (connection, transport) = makeConnection()
        await transport.deliver(greeting)
        _ = try await connection.connect()
        var outgoing = transport.sent.makeAsyncIterator()
        let pending = Task { try await connection.request("room_join", params: ["room_id": "secret"]) }
        _ = await outgoing.next()
        await transport.deliver(["id": "c1", "error": ["code": -32001, "message": "Denied", "data": ["reason": "private"]]])
        do {
            _ = try await pending.value
            XCTFail("expected an error")
        } catch let error as RPCError {
            XCTAssertEqual(error, RPCError(code: RPCError.Code.denied, message: "Denied", data: ["reason": "private"]))
        }
    }

    func testNotificationsStreamInOrderAndServerFramesReplace() async throws {
        let (connection, transport) = makeConnection()
        await transport.deliver(greeting)
        _ = try await connection.connect()
        await transport.deliver(["method": "message", "params": ["message_id": "100", "log_id": "100", "room_id": "general", "from": ["user_id": "alice"], "body": ["text": "hi"]]])
        await transport.deliver(raw: "not json at all")
        await transport.deliver(["method": "server", "params": ["apron": 9, "auth": ["token"], "ping": 30]])
        await transport.deliver(["method": "activity", "params": ["room_id": "general", "typing": 8]])

        var received: [WireNotification] = []
        for await notification in connection.notifications {
            received.append(notification)
            if received.count == 4 { break }
        }
        XCTAssertEqual(received.map(\.method), ["server", "message", "server", "activity"])
        XCTAssertEqual(received[3].params, ["room_id": "general", "typing": 8])
        let server = await connection.server
        XCTAssertEqual(server?.auth, ["token"])
        XCTAssertEqual(server?.ping, 30)
        let pingInterval = await connection.pingInterval
        XCTAssertEqual(pingInterval, .seconds(30))
        await connection.close()
    }

    func testPingsAtTheServersInterval() async throws {
        let (connection, transport) = makeConnection()
        await transport.deliver(["method": "server", "params": ["apron": 9, "auth": ["guest"], "ping": 0.02]])
        _ = try await connection.connect()
        var outgoing = transport.sent.makeAsyncIterator()
        let first = await outgoing.next()
        let second = await outgoing.next()
        XCTAssertEqual([first, second], [#"{"method":"ping"}"#, #"{"method":"ping"}"#])
        await connection.close()
    }

    func testServerCloseFailsPendingRequestsAndFinishesTheStream() async throws {
        let (connection, transport) = makeConnection()
        await transport.deliver(greeting)
        _ = try await connection.connect()
        var outgoing = transport.sent.makeAsyncIterator()
        let pending = Task { try await connection.request("me") }
        _ = await outgoing.next()
        await transport.dropFromServer()
        do {
            _ = try await pending.value
            XCTFail("expected a failure")
        } catch let error as Connection.Failure {
            XCTAssertEqual(error, .closed)
        }
        var remaining: [WireNotification] = []
        for await notification in connection.notifications { remaining.append(notification) }
        XCTAssertEqual(remaining.map(\.method), ["server"])
        do {
            _ = try await connection.request("me")
            XCTFail("a closed connection rejects requests")
        } catch let error as Connection.Failure {
            XCTAssertEqual(error, .closed)
        }
    }

    func testAnInvalidFirstFrameFailsConnect() async throws {
        let (connection, transport) = makeConnection()
        await transport.deliver(["method": "server", "params": ["auth": ["guest"]]])
        do {
            _ = try await connection.connect()
            XCTFail("expected invalidServerFrame")
        } catch let error as Connection.Failure {
            XCTAssertEqual(error, .invalidServerFrame)
        }
    }
}
