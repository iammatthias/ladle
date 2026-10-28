import Foundation

/// One connection's worth of text frames. `Connection` talks only to this, so tests drive it with
/// an in-memory transport and the app with a WebSocket.
public protocol FrameTransport: Sendable {
    /// Opens the transport. The first frame the server sends must then be readable with `receive`.
    func connect() async throws
    func send(_ text: String) async throws
    /// The next text frame. Throws `FrameTransportError.closed` once the peer closed.
    func receive() async throws -> String
    func close() async
}

public enum FrameTransportError: Error, Equatable, Sendable {
    case closed
    case binaryFrame
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
            if task.closeCode != .invalid { throw FrameTransportError.closed }
            throw error
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}
