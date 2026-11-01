import Foundation
import Observation

/// The viewer's media choices, shared by every server, as apron-web's `MediaSettings`: the policy,
/// the trusted sites ("sites I trust", so one list for all servers; each server's own origins
/// stay its own, in its `MediaGate`), the blocked sites, which win over all of those, and the
/// URLs tapped to load since launch. The policy and sites are kept in `media-settings.json`
/// beside `servers.json`; a file that cannot be read is the default, as apron-web treats
/// blocked storage.
@MainActor
@Observable
public final class MediaSettings {
    public private(set) var policy: MediaPolicy = .trusted
    /// `https:` origins, each once, in the order added.
    public private(set) var origins: [String] = []
    /// `https:` origins of the blocked hosts, each once, in the order added (`parseBlockedOrigins`).
    public private(set) var blocked: [String] = []
    /// What Load loaded on this launch; never saved.
    public private(set) var loadedOnce: Set<URL> = []

    @ObservationIgnored private let fileURL: URL?

    /// `directory` nil keeps the choices in memory only.
    public init(directory: URL? = nil) {
        fileURL = directory?.appending(path: "media-settings.json")
        guard let fileURL, let data = try? Data(contentsOf: fileURL), let json = try? JSONValue(parsing: data) else { return }
        policy = MediaPolicy(saved: json["policy"]?.stringValue)
        func list(_ key: String) -> String { (json[key]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: " ") }
        origins = Self.parseOrigins(list("origins"))
        blocked = Self.parseBlockedOrigins(list("blocked"))
    }

    public func update(policy: MediaPolicy, origins: [String]? = nil) {
        self.policy = policy
        if let origins { self.origins = Self.parseOrigins(origins.joined(separator: " ")) }
        save()
    }

    /// Always Load: the site joins the trusted sites, whatever the policy.
    public func trust(_ origin: String) {
        guard let parsed = Self.parseOrigins(origin).first, !origins.contains(parsed) else { return }
        update(policy: policy, origins: origins + [parsed])
    }

    /// Adds every site `text` names (`parseOrigins`); returns whether any was new.
    @discardableResult
    public func add(_ text: String) -> Bool {
        let new = Self.parseOrigins(text).filter { !origins.contains($0) }
        guard !new.isEmpty else { return false }
        update(policy: policy, origins: origins + new)
        return true
    }

    public func remove(_ origin: String) {
        update(policy: policy, origins: origins.filter { $0 != origin })
    }

    /// Block: the site joins the blocked sites, which win over the trusted ones; Trusted Sites
    /// still lists it.
    public func block(_ origin: String) {
        addBlocked(origin)
    }

    /// Blocks every site `text` names (`parseBlockedOrigins`); returns whether any was new.
    @discardableResult
    public func addBlocked(_ text: String) -> Bool {
        let new = Self.parseBlockedOrigins(text).filter { !blocked.contains($0) }
        guard !new.isEmpty else { return false }
        blocked += new
        save()
        return true
    }

    public func unblock(_ origin: String) {
        blocked.removeAll { $0 == origin }
        save()
    }

    /// Load: this one URL loads wherever it is, until the app quits.
    public func loadOnce(_ url: URL) {
        loadedOnce.insert(url)
    }

    /// The gate for a server under these choices. `heldToServer` keeps it to the server's own
    /// origins, as an export's is, whatever the policy and trusted sites say; the blocked sites
    /// and Load still hold.
    public func gate(serverURL: URL, server: ServerInfo?, heldToServer: Bool = false) -> MediaGate {
        MediaGate(serverURL: serverURL, server: server, policy: heldToServer ? .trusted : policy, viewerOrigins: heldToServer ? [] : origins,
                  loadedOnce: loadedOnce, blocked: blocked)
    }

    /// The `https:` origins `text` names, each once, in order, as apron-web's `parseMediaOrigins`:
    /// full URLs (`https://cdn.example/a.png`) or bare hosts (`cdn.example`), separated by spaces,
    /// commas or lines. A host needs a dot; anything else is dropped.
    public nonisolated static func parseOrigins(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { entry -> String? in
            let written = String(entry)
            let hasScheme = written.range(of: #"^[a-z][a-z0-9+.-]*://"#, options: [.regularExpression, .caseInsensitive]) != nil
            guard let url = URL(string: hasScheme ? written : "https://" + written), url.scheme?.lowercased() == "https",
                  url.host()?.contains(".") == true, let origin = MediaGate.origin(of: url) else { return nil }
            return seen.insert(origin).inserted ? origin : nil
        }
    }

    /// The sites `text` names to block, each once, in order, as `https:` origins of their hosts, as
    /// apron-web's `parseBlockedOrigins`: full `http(s)` URLs or bare hosts, separated by spaces,
    /// commas or lines, the scheme and port dropped since a block holds for the host whatever they
    /// are. Wildcards and anything else are dropped.
    public nonisolated static func parseBlockedOrigins(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { entry -> String? in
            let written = String(entry)
            guard !written.contains("*") else { return nil }
            let hasScheme = written.range(of: #"^[a-z][a-z0-9+.-]*://"#, options: [.regularExpression, .caseInsensitive]) != nil
            guard let url = URL(string: hasScheme ? written : "https://" + written), ["http", "https"].contains(url.scheme?.lowercased()),
                  let host = MediaGate.blockableHost(of: url) else { return nil }
            let origin = "https://" + (host.contains(":") ? "[\(host)]" : host)
            return seen.insert(origin).inserted ? origin : nil
        }
    }

    private func save() {
        guard let fileURL else { return }
        let json: JSONValue = ["policy": .string(policy.rawValue), "origins": .array(origins.map(JSONValue.string)),
                               "blocked": .array(blocked.map(JSONValue.string))]
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.serializedData().write(to: fileURL, options: .atomic)
    }
}
