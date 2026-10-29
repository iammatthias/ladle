import Foundation

/// One HTTP answer to the connection-status probe, as the fetch seam returns it. Header names are
/// lowercased.
public struct ProbeResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public typealias ConnectionStatusFetch = @Sendable (_ url: URL, _ origin: String?) async throws -> ProbeResponse

/// What a server said about why it will not take a connection: the probe's `error` and its
/// `Retry-After` (EXTENSIONS.md, `apron_connection_status`).
public struct ConnectionStatusReport: Sendable, Equatable {
    public var message: String
    public var retryAfter: Duration?
}

extension Connection {
    static let probeHeader = "apron-connection-status"
    static let maxProbeMessage = 200

    /// The probe URL for a WebSocket URL: the same address over `https:` (or `http:`) with
    /// `apron_connection_status=1`.
    public static func probeURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "wss", "https": components.scheme = "https"
        case "ws", "http": components.scheme = "http"
        default: return nil
        }
        components.fragment = nil
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "apron_connection_status" } + [URLQueryItem(name: "apron_connection_status", value: "1")]
        return components.url
    }

    /// Asks the server why the upgrade failed. Nil when the probe failed, the reply lacks
    /// `Apron-Connection-Status: 1` (an edge or a proxy answered), or the server says it is
    /// available.
    public static func probe(url: URL, origin: String?, fetch: ConnectionStatusFetch) async -> ConnectionStatusReport? {
        guard let probeURL = probeURL(for: url), let response = try? await fetch(probeURL, origin) else { return nil }
        return report(from: response)
    }

    static func report(from response: ProbeResponse) -> ConnectionStatusReport? {
        guard response.headers[probeHeader] == "1",
              let body = try? JSONValue(parsing: response.body),
              let error = body["error"]?.stringValue
        else { return nil }
        let message = String(TextDirection.withoutOverrides(error).trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxProbeMessage))
        guard !message.isEmpty else { return nil }
        let seconds = response.headers["retry-after"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return ConnectionStatusReport(message: message, retryAfter: seconds.flatMap { $0 > 0 ? .seconds($0) : nil })
    }
}

public enum ConnectionStatusProbe {
    /// The URLSession fetch: no cookies, no credentials, ten seconds.
    public static let live: ConnectionStatusFetch = { url, origin in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
        }
        return ProbeResponse(status: http.statusCode, headers: headers, body: body)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
}
