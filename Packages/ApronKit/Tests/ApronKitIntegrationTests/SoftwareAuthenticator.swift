import CryptoKit
import Foundation
@testable import ApronKit

/// A passkey provider in software, standing in for iOS's: P-256 keys, `none` attestation, user
/// presence and verification set, and `clientDataJSON` with the origin `https://<rpID>`, which is
/// what the platform writes for a native app.
@MainActor
final class SoftwareAuthenticator: PasskeyAuthenticator {
    struct Passkey {
        var id: Data
        var rpID: String
        var userHandle: Data
        var key: P256.Signing.PrivateKey
    }

    private(set) var passkeys: [Passkey] = []

    func credential(for challenge: PasskeyChallenge, name: String) async throws -> PasskeyCredential {
        let rpHash = Data(SHA256.hash(data: Data(challenge.rpID.utf8)))
        switch challenge.action {
        case .register:
            let user = try XCTUnwrapUser(challenge.user)
            let key = P256.Signing.PrivateKey()
            let id = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) })
            passkeys.append(Passkey(id: id, rpID: challenge.rpID, userHandle: user.id, key: key))
            let raw = key.publicKey.rawRepresentation
            let coseKey = CBOR.map([(.int(1), .int(2)), (.int(3), .int(-7)), (.int(-1), .int(1)),
                                    (.int(-2), .bytes(raw.prefix(32))), (.int(-3), .bytes(raw.suffix(32)))])
            var authData = rpHash
            authData.append(0x45)
            authData.append(contentsOf: [0, 0, 0, 0])
            authData.append(Data(count: 16))
            authData.append(contentsOf: [UInt8(id.count >> 8), UInt8(id.count & 0xFF)])
            authData.append(id)
            authData.append(coseKey.encoded)
            let attestation = CBOR.map([(.text("fmt"), .text("none")), (.text("attStmt"), .map([])), (.text("authData"), .bytes(authData))])
            return .registration(id: id, clientDataJSON: clientData("webauthn.create", challenge), attestationObject: attestation.encoded,
                                 attachment: .platform)
        case .login:
            guard let passkey = passkeys.last(where: { $0.rpID == challenge.rpID }) else { throw PasskeyError.cancelled }
            var authData = rpHash
            authData.append(0x05)
            authData.append(contentsOf: [0, 0, 0, 0])
            let clientData = clientData("webauthn.get", challenge)
            let signed = authData + Data(SHA256.hash(data: clientData))
            let signature = try passkey.key.signature(for: signed).derRepresentation
            return .assertion(id: passkey.id, clientDataJSON: clientData, authenticatorData: authData, signature: signature,
                              userHandle: passkey.userHandle, attachment: .platform)
        }
    }

    private func clientData(_ type: String, _ challenge: PasskeyChallenge) -> Data {
        Data(#"{"type":"\#(type)","challenge":"\#(Base64URL.encode(challenge.challenge))","origin":"https://\#(challenge.rpID)","crossOrigin":false}"#.utf8)
    }

    private func XCTUnwrapUser(_ user: PasskeyChallenge.User?) throws -> PasskeyChallenge.User {
        guard let user else { throw PasskeyError.invalidOptions }
        return user
    }
}

/// The CBOR (RFC 8949) an authenticator writes: integers, byte and text strings, maps.
indirect enum CBOR {
    case int(Int)
    case bytes(Data)
    case text(String)
    case map([(CBOR, CBOR)])

    var encoded: Data {
        switch self {
        case .int(let value) where value >= 0: Self.head(0, UInt64(value))
        case .int(let value): Self.head(1, UInt64(-1 - value))
        case .bytes(let data): Self.head(2, UInt64(data.count)) + data
        case .text(let text): Self.head(3, UInt64(text.utf8.count)) + Data(text.utf8)
        case .map(let pairs): pairs.reduce(Self.head(5, UInt64(pairs.count))) { $0 + $1.0.encoded + $1.1.encoded }
        }
    }

    private static func head(_ major: UInt8, _ value: UInt64) -> Data {
        let type = major << 5
        switch value {
        case 0 ..< 24: return Data([type | UInt8(value)])
        case 24 ..< 0x100: return Data([type | 24, UInt8(value)])
        case 0x100 ..< 0x10000: return Data([type | 25, UInt8(value >> 8), UInt8(value & 0xFF)])
        default: return Data([type | 26] + (0 ..< 4).reversed().map { UInt8((value >> ($0 * 8)) & 0xFF) })
        }
    }
}
