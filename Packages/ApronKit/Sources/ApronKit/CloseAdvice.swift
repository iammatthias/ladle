import Foundation

/// What a server's close frame asks of a client, after Cloudflare's client guide
/// (apron-server-cloudflare `docs/limits.md`, "Closed connections"); the Rust server closes with
/// the same codes and reasons.
public enum CloseAdvice: Hashable, Sendable {
    /// Reconnect with the usual backoff: an idle or failed delivery (1001, 1011), or a policy close
    /// that a fresh connection clears (frame rate, pending frames, repeated violations).
    case reconnect
    /// 1013: the server, or this address, is over a budget. Minutes of backoff, not seconds.
    case backOff
    /// 1008 "Authentication timed out": the connection never signed in. Connecting again would
    /// only be closed again, so wait until the user signs in.
    case awaitSignIn
    /// Any other 1008 is about the credentials (a token replaced, an account removed, a bot signed
    /// out after a week): the same token would only be refused, so ask the user to sign in again.
    case credentialsRevoked(String)

    /// How long a 1013 close holds off the next connection, at least.
    public static let backOffDelay = Duration.seconds(120)

    /// Policy closes that say nothing about the credentials.
    static let transientPolicyReasons: Set<String> = ["Frame rate limit reached", "Too many pending frames", "Repeated policy violations"]

    public init(_ frame: CloseFrame) {
        switch frame.code {
        case 1013:
            self = .backOff
        case 1008 where frame.reason == "Authentication timed out":
            self = .awaitSignIn
        case 1008 where Self.transientPolicyReasons.contains(frame.reason):
            self = .reconnect
        case 1008:
            self = .credentialsRevoked(frame.reason)
        default:
            self = .reconnect
        }
    }
}
