import ApronKit
import Foundation

/// A sentence to show for an error from a session operation.
func errorText(_ error: any Error) -> String {
    switch error {
    case let error as RPCError:
        return error.message.isEmpty ? "The server refused the request (\(error.code))." : error.message
    case Connection.Failure.closed:
        return "The connection closed before the server answered. Try again."
    case ServerSession.Failure.notConnected:
        return "Not connected to this server."
    case ServerSession.Failure.notSignedIn:
        return "Sign in to this server first."
    case ServerSession.Failure.unsupported(let capability):
        return "This server does not support \(capability)."
    default:
        return error.localizedDescription
    }
}
