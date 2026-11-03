import Foundation

/// Where a relay delivers this device's pushes (§4.9.2 kind `relay`): the `url` and bearer
/// `token` the relay gave for its APNs device token (docs/PUSH.md).
public struct RelayEndpoint: Hashable, Sendable {
    public var url: URL
    public var token: String?

    public init(url: URL, token: String? = nil) {
        self.url = url
        self.token = token
    }

    /// What Ladle asks its relay for an endpoint: `POST <relay>/v1/register` with the APNs device
    /// token in hex, its environment (`development` or `production`) and topic (the bundle ID).
    public static func request(relay: URL, deviceToken: Data, environment: String, topic: String) -> URLRequest {
        var request = URLRequest(url: relay.appending(path: "v1/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        request.httpBody = JSONValue.object(["device_token": .string(token), "environment": .string(environment),
                                             "topic": .string(topic)]).serializedData()
        return request
    }

    /// The relay's answer, `{url, token}`: nil unless `url` is https.
    public init?(response data: Data) {
        guard let json = try? JSONValue(parsing: data), let text = json["url"]?.stringValue, let url = URL(string: text),
              url.scheme == "https" else { return nil }
        self.init(url: url, token: json["token"]?.stringValue)
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["url": .string(url.absoluteString)]
        if let token { object["token"] = .string(token) }
        return .object(object)
    }

    public init?(json: JSONValue?) {
        guard let text = json?["url"]?.stringValue, let url = URL(string: text) else { return nil }
        self.init(url: url, token: json?["token"]?.stringValue)
    }
}

/// An account's push registration on one server, as the server answered it.
public enum PushState: Hashable, Sendable {
    case off
    case registering
    /// Registered at this `url`, waking for `wake` (nil: the server's defaults).
    case on(url: URL, wake: [String]?)
    /// The server refused it, with its words.
    case refused(String)

    public var isOn: Bool { if case .on = self { true } else { false } }
}

/// Why push can't alert while Ladle is closed for an account, for the Notifications note.
public enum PushBlocker: Hashable, Sendable {
    /// This build has no `aps-environment` entitlement (docs/PUSH.md).
    case notInThisBuild
    /// The server offers no `relay` kind (§4.9.2).
    case serverOffersNone
    /// A guest: servers refuse a guest's registration, and its `user_id` changes each connection.
    case signIn
    /// No relay is set on this device.
    case noRelay
    /// iOS has not given this device an APNs token yet.
    case noDeviceToken
}

extension ServerSession {
    /// The server offers push kind `relay` (§4.9).
    public var offersRelayPush: Bool { server?.push?["relay"]?.objectValue != nil }

    /// The wake scopes the server lists (`server.push.wake`).
    public var offeredWake: [String] { server?.push?["wake"]?.arrayValue?.compactMap(\.stringValue) ?? [] }

    /// `push_register` for kind `relay` (§4.9.1): the relay's `url` and `token`, the account's
    /// `push_id`, and `wake`, the checked scopes the server pushes, left out when it lists none.
    /// Without `keys` the server posts the payload as JSON.
    public func pushRegisterParams(_ endpoint: RelayEndpoint, pushID: String, scopes: [NotifyScope]) -> JSONValue {
        var params: [String: JSONValue] = ["kind": "relay", "url": .string(endpoint.url.absoluteString), "push_id": .string(pushID)]
        if let token = endpoint.token { params["token"] = .string(token) }
        if let wake = NotifyScope.wake(scopes, offered: offeredWake) { params["wake"] = .array(wake.map(JSONValue.string)) }
        return .object(params)
    }

    /// Registers push for the account signed in, or says why it can't: a guest, or a server
    /// without `relay`. Sent after each sign-in and when the scopes change; the same `url`
    /// replaces the earlier registration (§4.9.1).
    public func registerPush(_ endpoint: RelayEndpoint, pushID: String, scopes: [NotifyScope]) async {
        guard status == .signedIn, offersRelayPush, !isGuest else { return }
        let params = pushRegisterParams(endpoint, pushID: pushID, scopes: scopes)
        push = .registering
        do {
            _ = try await request("push_register", params)
            push = .on(url: endpoint.url, wake: params["wake"]?.arrayValue?.compactMap(\.stringValue))
        } catch {
            push = .refused(errorText(error))
        }
    }

    /// Unregisters this account's push (`push_unregister`), as before signing out or once
    /// notifications are turned off here. Unregistering an unknown `url` succeeds (§4.9.1).
    public func unregisterPush() async {
        guard case .on(let url, _) = push else { return }
        push = .off
        guard status == .signedIn else { return }
        _ = try? await request("push_unregister", ["url": .string(url.absoluteString)])
    }

    /// Why push can't alert for this account while Ladle is closed; nil when it can.
    public func pushBlocker(inBuild: Bool, relay: URL?, endpoint: RelayEndpoint?) -> PushBlocker? {
        if !inBuild { return .notInThisBuild }
        if !offersRelayPush { return .serverOffersNone }
        if isGuest { return .signIn }
        if relay == nil { return .noRelay }
        if endpoint == nil { return .noDeviceToken }
        return nil
    }
}
