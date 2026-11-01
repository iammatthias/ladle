import ApronKit
import AuthenticationServices
import UIKit

/// The system passkey sheet (`ASAuthorizationPlatformPublicKeyCredentialProvider`) for one
/// ceremony that `ServerSession.usePasskey` has checked: the RP ID is the server's, an associated
/// domain of this build, and the origin the platform signs. The sheet also offers a passkey on
/// another device by QR code.
struct PlatformPasskeys: PasskeyAuthenticator {
    @MainActor
    func credential(for challenge: PasskeyChallenge, name: String) async throws -> PasskeyCredential {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: challenge.rpID)
        let verification = ASAuthorizationPublicKeyCredentialUserVerificationPreference(rawValue: challenge.userVerification)
        let request: ASAuthorizationRequest
        switch challenge.action {
        case .register:
            guard let user = challenge.user else { throw PasskeyError.invalidOptions }
            let registration = provider.createCredentialRegistrationRequest(challenge: challenge.challenge, name: name, userID: user.id)
            registration.userVerificationPreference = verification
            registration.excludedCredentials = challenge.excludedCredentials.map(ASAuthorizationPlatformPublicKeyCredentialDescriptor.init(credentialID:))
            request = registration
        case .login:
            let assertion = provider.createCredentialAssertionRequest(challenge: challenge.challenge)
            assertion.userVerificationPreference = verification
            assertion.allowedCredentials = challenge.allowedCredentials.map(ASAuthorizationPlatformPublicKeyCredentialDescriptor.init(credentialID:))
            request = assertion
        }
        return try await Ceremony(request).run()
    }
}

/// One `ASAuthorizationController` run. It keeps itself alive until the sheet answers, since the
/// controller holds its delegate weakly.
@MainActor
private final class Ceremony: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let controller: ASAuthorizationController
    private var continuation: CheckedContinuation<PasskeyCredential, any Error>?
    private var keptAlive: Ceremony?

    init(_ request: ASAuthorizationRequest) {
        controller = ASAuthorizationController(authorizationRequests: [request])
    }

    func run() async throws -> PasskeyCredential {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            keptAlive = self
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<PasskeyCredential, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
        keptAlive = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        switch authorization.credential {
        case let made as ASAuthorizationPlatformPublicKeyCredentialRegistration:
            guard let attestation = made.rawAttestationObject else { return finish(.failure(PasskeyError.failed("The passkey came back without its attestation."))) }
            finish(.success(.registration(id: made.credentialID, clientDataJSON: made.rawClientDataJSON, attestationObject: attestation,
                                          attachment: Self.attachment(made.attachment))))
        case let found as ASAuthorizationPlatformPublicKeyCredentialAssertion:
            finish(.success(.assertion(id: found.credentialID, clientDataJSON: found.rawClientDataJSON, authenticatorData: found.rawAuthenticatorData,
                                       signature: found.signature, userHandle: found.userID, attachment: Self.attachment(found.attachment))))
        default:
            finish(.failure(PasskeyError.failed("The system returned something other than a passkey.")))
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        if let error = error as? ASAuthorizationError, error.code == .canceled {
            finish(.failure(PasskeyError.cancelled))
        } else {
            finish(.failure(PasskeyError.failed(error.localizedDescription)))
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // A tap started the ceremony, so a scene is on screen.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? UIWindow(windowScene: scenes[0])
    }

    private static func attachment(_ attachment: ASAuthorizationPublicKeyCredentialAttachment) -> PasskeyCredential.Attachment {
        attachment == .crossPlatform ? .crossPlatform : .platform
    }
}
