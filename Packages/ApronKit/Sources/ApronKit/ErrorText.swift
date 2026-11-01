import Foundation

/// A sentence to show for an error from a session operation: in the app's banners, and in the
/// notice a failed command leaves.
public func errorText(_ error: any Error) -> String {
    switch error {
    case let error as RPCError:
        // A wait the server asked for says when to try again, as apron-web's `userFacingRpcError`.
        return error.message.isEmpty ? "The server refused the request (\(error.code))." : error.userFacing
    case Connection.Failure.closed:
        return "The connection closed before the server answered. Try again."
    case ServerSession.Failure.notConnected:
        return "Not connected to this server."
    case ServerSession.Failure.notSignedIn:
        return "Sign in to this server first."
    case ServerSession.Failure.unsupported(let capability):
        return "This server does not support \(capability)."
    case ServerSession.Failure.attachmentNotAccepted:
        return "The server didn't accept the file."
    case ServerSession.Failure.badSignInPage:
        return "The server's sign-in page isn't a secure web address, so Ladle won't open it."
    case ServerSession.Failure.noAddition:
        return "The request for this code is no longer open. Start again."
    case let error as PasskeyError:
        return error.message
    default:
        return error.localizedDescription
    }
}
