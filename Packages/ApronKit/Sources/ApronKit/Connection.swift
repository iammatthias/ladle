import Foundation

/// One protocol connection (§1): matches replies to requests by `id`, streams notifications, and
/// keeps the latest `server` frame. It owns no chat state; `ReplayStore` does that.
public actor Connection {
    public enum Failure: Error, Equatable, Sendable {
        /// The transport closed, or `close()` was called, before a reply arrived.
        case closed
        /// The server's first frame was not a valid `server` frame (§3.1).
        case invalidServerFrame
        case alreadyConnected
        /// The WebSocket handshake was answered with this HTTP status instead of an upgrade, such
        /// as 403 for an `Origin` the server does not accept.
        case rejected(status: Int)
    }

    /// The latest `server` frame; each one fully replaces the previous (§3.1).
    public private(set) var server: ServerInfo?
    /// Every notification in arrival order, `server` frames included. Finishes when the connection closes.
    public nonisolated let notifications: AsyncStream<WireNotification>

    private let transport: any FrameTransport
    private let makeRequestID: @Sendable () -> String
    private let notificationSink: AsyncStream<WireNotification>.Continuation
    private var pending: [String: Slot] = [:]
    private var serverWaiter: CheckedContinuation<ServerInfo, any Error>?
    private var reader: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var isClosed = false
    /// Outgoing frames, written by one task so they reach the wire in call order.
    private let outbox: AsyncStream<Outbound>.Continuation
    private let outboxFrames: AsyncStream<Outbound>
    private var writer: Task<Void, Never>?

    /// A sent request: waiting for its reply, with or without a waiter, or replied to and not yet read.
    private enum Slot {
        case waiting(CheckedContinuation<JSONValue, any Error>?)
        case replied(Result<JSONValue, any Error>)
    }

    /// A request that is on its way; `value` awaits the reply.
    public struct Reply: Sendable {
        public let id: String
        let connection: Connection

        public var value: JSONValue {
            get async throws { try await connection.reply(to: id) }
        }
    }

    private struct Outbound: Sendable {
        var text: String
        var requestID: String?
    }

    /// The last error the server sent without an `id` (§1.1), such as `denied` or a
    /// `retry_after` at capacity. The server may close the connection after it.
    public private(set) var connectionError: RPCError?

    public init(transport: any FrameTransport, makeRequestID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.transport = transport
        self.makeRequestID = makeRequestID
        (notifications, notificationSink) = AsyncStream.makeStream(of: WireNotification.self, bufferingPolicy: .unbounded)
        (outboxFrames, outbox) = AsyncStream.makeStream(of: Outbound.self, bufferingPolicy: .unbounded)
    }

    /// Opens the transport and returns the server's greeting, the first frame it sends (§3.1).
    public func connect() async throws -> ServerInfo {
        guard reader == nil else { throw Failure.alreadyConnected }
        try await transport.connect()
        reader = Task { await readLoop() }
        writer = Task { await writeLoop() }
        return try await withCheckedThrowingContinuation { serverWaiter = $0 }
    }

    /// Sends a request and awaits its reply. An `error` reply throws its `RPCError`.
    public func request(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        try await send(method, params: params).value
    }

    /// Queues a request without waiting for its reply. Requests reach the wire in the order of
    /// these calls, so a client can pipeline `room_list` right behind `auth` (§3.2.2).
    public func send(_ method: String, params: JSONValue? = nil) throws -> Reply {
        guard !isClosed else { throw Failure.closed }
        let request = Request(id: makeRequestID(), method: method, params: params)
        pending[request.id] = .waiting(nil)
        outbox.yield(Outbound(text: request.encoded.serialized(), requestID: request.id))
        return Reply(id: request.id, connection: self)
    }

    func reply(to id: String) async throws -> JSONValue {
        switch pending[id] {
        case .replied(let outcome):
            pending[id] = nil
            return try outcome.get()
        case .waiting:
            return try await withCheckedThrowingContinuation { pending[id] = .waiting($0) }
        case nil:
            throw Failure.closed
        }
    }

    private func resolve(_ id: String, with outcome: Result<JSONValue, any Error>) {
        switch pending[id] {
        case .waiting(let waiter?):
            pending[id] = nil
            waiter.resume(with: outcome)
        case .waiting(nil):
            pending[id] = .replied(outcome)
        case .replied, nil:
            break
        }
    }

    /// Queues a notification, such as `ping`, behind every earlier frame.
    public func notify(_ method: String, params: JSONValue? = nil) throws {
        guard !isClosed else { throw Failure.closed }
        outbox.yield(Outbound(text: WireNotification(method: method, params: params).encoded.serialized()))
    }

    /// Seconds between pings from the latest `server` frame; nil when the server wants none.
    public var pingInterval: Duration? {
        guard let seconds = server?.ping, seconds > 0 else { return nil }
        return .seconds(seconds)
    }

    public func close() async {
        guard !isClosed else { return }
        await transport.close()
        finish(with: Failure.closed)
    }

    // MARK: - Internals

    private func writeLoop() async {
        for await frame in outboxFrames {
            do {
                try await transport.send(frame.text)
            } catch {
                if let id = frame.requestID { resolve(id, with: .failure(error)) }
            }
        }
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                handle(try await transport.receive())
            } catch FrameTransportError.handshakeRejected(let status) {
                finish(with: .rejected(status: status))
                return
            } catch {
                finish(with: .closed)
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let frame = try? Frame(parsing: text) else { return }
        switch frame {
        case .notification(let notification):
            if notification.method == "server" { handleServer(notification.params) }
            notificationSink.yield(notification)
        case .response(let response):
            resolve(response.id, with: response.outcome.mapError { $0 as any Error })
        case .error(let error):
            connectionError = error
            serverWaiter?.resume(throwing: error)
            serverWaiter = nil
        case .request:
            break
        }
    }

    private func handleServer(_ params: JSONValue?) {
        guard let info = ServerInfo(params: params) else {
            serverWaiter?.resume(throwing: Failure.invalidServerFrame)
            serverWaiter = nil
            return
        }
        server = info
        serverWaiter?.resume(returning: info)
        serverWaiter = nil
        restartPinger()
    }

    private func restartPinger() {
        pinger?.cancel()
        guard let interval = pingInterval else { return }
        pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                try? notify("ping")
            }
        }
    }

    private func finish(with error: Failure) {
        isClosed = true
        reader?.cancel()
        pinger?.cancel()
        writer?.cancel()
        outbox.finish()
        for id in Array(pending.keys) { resolve(id, with: .failure(error)) }
        serverWaiter?.resume(throwing: error)
        serverWaiter = nil
        notificationSink.finish()
    }
}
