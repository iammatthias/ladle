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
    }

    /// The latest `server` frame; each one fully replaces the previous (§3.1).
    public private(set) var server: ServerInfo?
    /// Every notification in arrival order, `server` frames included. Finishes when the connection closes.
    public nonisolated let notifications: AsyncStream<WireNotification>

    private let transport: any FrameTransport
    private let makeRequestID: @Sendable () -> String
    private let notificationSink: AsyncStream<WireNotification>.Continuation
    private var pending: [String: CheckedContinuation<JSONValue, any Error>] = [:]
    private var serverWaiter: CheckedContinuation<ServerInfo, any Error>?
    private var reader: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var isClosed = false

    public init(transport: any FrameTransport, makeRequestID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.transport = transport
        self.makeRequestID = makeRequestID
        (notifications, notificationSink) = AsyncStream.makeStream(of: WireNotification.self, bufferingPolicy: .unbounded)
    }

    /// Opens the transport and returns the server's greeting, the first frame it sends (§3.1).
    public func connect() async throws -> ServerInfo {
        guard reader == nil else { throw Failure.alreadyConnected }
        try await transport.connect()
        reader = Task { await readLoop() }
        return try await withCheckedThrowingContinuation { serverWaiter = $0 }
    }

    /// Sends a request and awaits its reply. An `error` reply throws its `RPCError`.
    public func request(_ method: String, params: JSONValue? = nil) async throws -> JSONValue {
        guard !isClosed else { throw Failure.closed }
        let request = Request(id: makeRequestID(), method: method, params: params)
        return try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            Task { await deliver(request.encoded, failing: request.id) }
        }
    }

    /// Sends a notification, such as `ping`.
    public func notify(_ method: String, params: JSONValue? = nil) async throws {
        guard !isClosed else { throw Failure.closed }
        try await transport.send(WireNotification(method: method, params: params).encoded.serialized())
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

    private func deliver(_ frame: JSONValue, failing id: String) async {
        do {
            try await transport.send(frame.serialized())
        } catch {
            pending.removeValue(forKey: id)?.resume(throwing: error)
        }
    }

    private func readLoop() async {
        while !Task.isCancelled {
            do {
                handle(try await transport.receive())
            } catch {
                finish(with: Failure.closed)
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
            pending.removeValue(forKey: response.id)?.resume(with: response.outcome.mapError { $0 as any Error })
        case .error(let error):
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
                try? await notify("ping")
            }
        }
    }

    private func finish(with error: Failure) {
        isClosed = true
        reader?.cancel()
        pinger?.cancel()
        for continuation in pending.values { continuation.resume(throwing: error) }
        pending = [:]
        serverWaiter?.resume(throwing: error)
        serverWaiter = nil
        notificationSink.finish()
    }
}
