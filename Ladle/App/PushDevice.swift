import ApronKit
import Foundation
import Observation

/// This device's APNs side of push (docs/PUSH.md), off unless the build carries
/// `aps-environment`: the Info.plist key `LadlePushEnvironment` is `development` or `production`
/// then (`LADLE_PUSH` in Config/Domains.xcconfig), and empty otherwise.
@MainActor
@Observable
final class PushDevice {
    static let shared = PushDevice()

    /// The APNs environment this build was signed for; nil when it has no push.
    let environment: String? = {
        let value = Bundle.main.object(forInfoDictionaryKey: "LadlePushEnvironment") as? String ?? ""
        return ["development", "production"].contains(value) ? value : nil
    }()

    /// The token iOS gave this launch, once it has.
    var token: Data?

    /// Asks the relay for this device's endpoint (`RelayEndpoint`) and registers each server again
    /// with it. Each launch asks once the token comes, and again when the relay changes.
    func fetchEndpoint(for store: SessionStore) async {
        let settings = store.alerts.settings
        guard let environment, let token, let relay = settings.relay, let topic = Bundle.main.bundleIdentifier else { return }
        let request = RelayEndpoint.request(relay: relay, deviceToken: token, environment: environment, topic: topic)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, let endpoint = RelayEndpoint(response: data),
              settings.relay == relay else { return }
        settings.setEndpoint(endpoint)
        await store.syncPush()
    }
}
