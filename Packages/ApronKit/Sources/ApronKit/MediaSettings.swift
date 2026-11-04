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

    /// Whether Always Load was chosen in the export open now, as apron-web's `trust` ends its
    /// page's `limit` (#209): the export then loads from the trusted sites too, never any site.
    public private(set) var exportHoldLifted = false

    /// Always Load: the site joins the trusted sites, whatever the policy; chosen on an export's
    /// held media (`held`), that export loads from the trusted sites from then on. The policy saved
    /// stays the one chosen.
    public func trust(_ origin: String, held: Bool = false) {
        if held { exportHoldLifted = true }
        guard let parsed = Self.parseOrigins(origin).first, !origins.contains(parsed) else { return }
        update(policy: policy, origins: origins + [parsed])
    }

    /// An export opens held to its own sites, as the web's `limit` on loading its page.
    public func holdExport() {
        exportHoldLifted = false
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
    /// origins, as an export's is, whatever the policy and trusted sites say, until Always Load
    /// there adds the trusted sites (`exportHoldLifted`); the blocked sites and Load still hold.
    public func gate(serverURL: URL, server: ServerInfo?, heldToServer: Bool = false) -> MediaGate {
        let held = heldToServer && !exportHoldLifted
        return MediaGate(serverURL: serverURL, server: server, policy: heldToServer ? .trusted : policy, viewerOrigins: held ? [] : origins,
                         loadedOnce: loadedOnce, blocked: blocked, held: held)
    }

    /// The `https:` origins `text` names, each once, in order, as apron-web's `parseMediaOrigins`:
    /// full URLs (`https://cdn.example/a.png`) or bare hosts (`cdn.example`), separated by spaces,
    /// commas or lines. A host needs a dot; anything else is dropped.
    public nonisolated static func parseOrigins(_ text: String) -> [String] {
        parseEntries(text) { url in
            url.scheme?.lowercased() == "https" && url.host()?.contains(".") == true ? MediaGate.origin(of: url) : nil
        }
    }

    /// The sites `text` names to block, each once, in order, as `https:` origins of their hosts, as
    /// apron-web's `parseBlockedOrigins`: full `http(s)` URLs or bare hosts, separated by spaces,
    /// commas or lines, the scheme and port dropped since a block holds for the host whatever they
    /// are. Wildcards, single labels but `localhost`, and anything else are dropped.
    public nonisolated static func parseBlockedOrigins(_ text: String) -> [String] {
        parseEntries(text) { url in
            guard let host = MediaGate.blockableHost(of: url) else { return nil }
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            // A single label other than localhost (`com`, or `tracker:` read as one) would block a whole top-level domain.
            guard labels.allSatisfy({ !$0.isEmpty }), !host.contains("*"), labels.count > 1 || host == "localhost" else { return nil }
            return "https://" + (host.contains(":") ? "[\(host)]" : host)
        }
    }

    /// What `keep` makes of each URL named in `text`, separated by spaces, commas or lines: each
    /// once, in order (apron-web's `parseEntries`).
    private nonisolated static func parseEntries(_ text: String, keep: (URL) -> String?) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { entry -> String? in
            guard let value = entryURL(String(entry)).flatMap(keep) else { return nil }
            return seen.insert(value).inserted ? value : nil
        }
    }

    /// The `http(s):` URL an entry names, as apron-web's `entryUrl`: one that starts with a scheme
    /// and `//` as it stands (`ftp://` names none), anything else as it stands or else as a bare
    /// host (`cdn.example`, or `cdn.example:443`, which reads alone as a scheme) under `https:`.
    private nonisolated static func entryURL(_ entry: String) -> URL? {
        // Only a scheme at the start names one: a bare host can have `://` further on, in its query.
        let hasScheme = entry.range(of: #"^[a-z][a-z0-9+.-]*://"#, options: [.regularExpression, .caseInsensitive]) != nil
        for candidate in hasScheme ? [entry] : [entry, "https://" + entry] {
            // The web's URL reads `http:/host` and `http:host` as `http://host`; Foundation leaves them without a host.
            let written = candidate.replacingOccurrences(of: #"^(https?):[/\\]*"#, with: "$1://", options: [.regularExpression, .caseInsensitive])
            if let url = URL(string: written), ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil { return url }
        }
        return nil
    }

    private func save() {
        guard let fileURL else { return }
        let json: JSONValue = ["policy": .string(policy.rawValue), "origins": .array(origins.map(JSONValue.string)),
                               "blocked": .array(blocked.map(JSONValue.string))]
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.serializedData().write(to: fileURL, options: .atomic)
    }
}
