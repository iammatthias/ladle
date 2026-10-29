import Foundation

/// One connection's worth of text frames. `Connection` talks only to this, so tests drive it with
/// an in-memory transport and the app with a WebSocket.
public protocol FrameTransport: Sendable {
    /// Opens the transport. The first frame the server sends must then be readable with `receive`.
    func connect() async throws
    func send(_ text: String) async throws
    /// The next text frame. Throws `FrameTransportError.closedByServer` once the peer sent a
    /// close frame, and `FrameTransportError.closed` once the transport closed otherwise.
    func receive() async throws -> String
    func close() async
}

public enum FrameTransportError: Error, Equatable, Sendable {
    case closed
    /// The server closed the WebSocket with this close frame.
    case closedByServer(CloseFrame)
    case binaryFrame
    /// The server answered the upgrade request with this HTTP status instead of 101.
    case handshakeRejected(status: Int)
}

/// The code and reason of a WebSocket close frame (RFC 6455 §7.4). Servers say with them why
/// they closed a connection, such as 1008 "Device token replaced; sign in with the new one".
public struct CloseFrame: Hashable, Sendable {
    public var code: Int
    public var reason: String

    public init(code: Int, reason: String) {
        self.code = code
        self.reason = reason
    }
}

/// A WebSocket over URLSession. `origin` is sent as the `Origin` header on the upgrade request:
/// the server binds bearer tokens to the origin of the client that obtained them (§3.2.1, §4.10),
/// so the app presents the origin its token belongs to.
public final class WebSocketTransport: FrameTransport {
    private let task: URLSessionWebSocketTask

    public init(url: URL, origin: String?, session: URLSession = .shared) {
        var request = URLRequest(url: url)
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        task = session.webSocketTask(with: request)
    }

    public func connect() async throws {
        task.resume()
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data):
                guard let text = String(data: data, encoding: .utf8) else { throw FrameTransportError.binaryFrame }
                return text
            @unknown default: throw FrameTransportError.binaryFrame
            }
        } catch let error as FrameTransportError {
            throw error
        } catch {
            if let response = task.response as? HTTPURLResponse, response.statusCode != 101 {
                throw FrameTransportError.handshakeRejected(status: response.statusCode)
            }
            if task.closeCode != .invalid {
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                throw FrameTransportError.closedByServer(CloseFrame(code: task.closeCode.rawValue, reason: reason))
            }
            throw error
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
