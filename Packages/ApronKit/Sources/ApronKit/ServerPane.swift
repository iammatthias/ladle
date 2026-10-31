import Foundation

/// The server you are connected to, as apron-web's ServerPane shows it from the rooms list's
/// head: how it shows itself (§3.1), how the connection stands, who you are there, its address,
/// and the protocol version.
public struct ServerPane: Hashable, Sendable {
    public enum Tone: Hashable, Sendable {
        case ok, warn, danger
    }

    public let name: String
    public let host: String
    /// Its `description` (§3.1), CommonMark.
    public let description: String?
    /// "Connected", "Connecting…", "Reconnecting…", or what is wrong.
    public let connection: String
    /// Green connected, amber on its way, red offline or stopped.
    public let tone: Tone
    /// "Signed in as Ada" with " (guest)" for a guest; nil before there is a you.
    public let signedInAs: String?
    /// The WebSocket address, to copy.
    public let address: String
    /// "Apron 9", from the `server` frame.
    public let protocolVersion: String?
}

extension ServerSession {
    public var pane: ServerPane {
        let tone: ServerPane.Tone
        let words: String
        switch status {
        case .signedIn, .signedOut:
            (tone, words) = (.ok, "Connected")
        case .offline, .stopped:
            (tone, words) = (.danger, ConnectionState(status)?.title(record) ?? "Offline")
        default:
            (tone, words) = (.warn, ConnectionState(status)?.title(record) ?? "Connecting…")
        }
        let description = server?.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServerPane(
            name: serverName,
            host: record.url.host() ?? record.url.absoluteString,
            description: description?.isEmpty == false ? description : nil,
            connection: words,
            tone: tone,
            signedInAs: you.map { "Signed in as \(TextDirection.isolated(displayName(for: $0)))" + (isGuest ? " (guest)" : "") },
            address: record.url.absoluteString,
            protocolVersion: server.map { "Apron \($0.apron)" }
        )
    }
}
