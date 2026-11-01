import Foundation
import Observation

/// A link a site in `LinkSites` can describe.
public struct PreviewLink: Sendable {
    public var lookup: LinkLookup
    public var site: LinkSite
    public var url: String { lookup.url }
}

/// apron-web's `link-previews.ts`: previews the sender builds for links in a draft, sent as
/// `link` embeds whose `og` (§4.8.1) describes what the link points to. The server has the last
/// word on `og` and may keep, replace or drop it. A link on a site in `LinkSites` is asked about
/// from that site's API once typing pauses; a message sent before the answer, or for a link the
/// API won't describe, carries a card built from the URL.
///
/// Sites limit unauthenticated calls, so each link is asked for once, and a rate-limited answer
/// holds further requests to that site until the limit resets. One instance serves every
/// composer on the device, as the web's one per page.
@MainActor
@Observable
public final class DraftLinkPreviews {
    /// At most this many previews per message.
    public nonisolated static let maxPerMessage = 3
    static let cacheMax = 100

    /// An API's answer: its status, its headers by lowercased name, and its body.
    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data

        public init(status: Int, headers: [String: String] = [:], body: Data) {
            self.status = status
            self.headers = headers
            self.body = body
        }
    }

    /// A GET of a site's API with the lookup's headers.
    public typealias Fetch = @Sendable (URL, [String: String]) async throws -> Response

    private var known: [String: OpenGraph?] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var blockedUntil: [String: Date] = [:]
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sites: [String: LinkSite]

    public init(fetch: @escaping Fetch = LinkSiteFetch.live, now: @escaping @Sendable () -> Date = Date.init,
                sites: [String: LinkSite] = LinkSites.all) {
        self.fetch = fetch
        self.now = now
        self.sites = sites
    }

    /// The previewable links in `text`, as `findLinks` finds them with this instance's sites.
    public func links(in text: String, skipping skip: [String] = []) -> [PreviewLink] {
        Self.findLinks(in: text, skipping: skip, sites: sites)
    }

    /// Fetches previews for the links in `text`; returns when they have settled.
    public func prefetch(_ text: String) async {
        let loads = links(in: text).map { link in Task { await self.load(link) } }
        for load in loads { await load.value }
    }

    /// `link` embeds for the links in `text`: fetched details where they've arrived, else what
    /// the URL says. Links in `dismissed` are left out.
    public func embeds(in text: String, dismissed: [String] = []) -> [Embed] {
        links(in: text, skipping: dismissed).compactMap { link in
            guard let og = (known[link.url] ?? nil) ?? link.lookup.fallback else { return nil }
            return Embed(["kind": "link", "url": .string(link.url), "og": og.json])
        }
    }

    private func load(_ link: PreviewLink) async {
        if known.keys.contains(link.url) { return }
        if let running = pending[link.url] { return await running.value }
        if now() < blockedUntil[link.site.name] ?? .distantPast { return }
        let request = Task { await self.request(link) }
        pending[link.url] = request
        await request.value
        pending[link.url] = nil
    }

    private func request(_ link: PreviewLink) async {
        guard let api = URL(string: link.lookup.api), let response = try? await fetch(api, link.lookup.headers) else { return }
        if link.site.limited.contains(response.status) {
            blockedUntil[link.site.name] = Self.retryAt(response, now: now())
            return
        }
        var og: OpenGraph?
        if (200 ..< 300).contains(response.status) {
            guard let json = try? JSONValue(parsing: response.body) else { return }
            og = link.lookup.preview(LinkSites.record(json))
        } else if !link.site.missing.contains(response.status) {
            return
        }
        // A link with nothing to describe (private, or not there) is remembered too, so it isn't asked for again.
        remember(link.url, og)
    }

    private func remember(_ url: String, _ og: OpenGraph?) {
        if known.count >= Self.cacheMax, let oldest = order.first {
            order.removeFirst()
            known[oldest] = nil
        }
        known[url] = .some(og)
        order.append(url)
    }

    /// When a limited answer says to try again: its `Retry-After` seconds, or `X-RateLimit-Reset`
    /// time, else in a minute.
    nonisolated static func retryAt(_ response: Response, now: Date) -> Date {
        if let text = response.headers["retry-after"], !text.isEmpty, let after = Double(text), after.isFinite, after >= 0 {
            return now.addingTimeInterval(after)
        }
        if let reset = response.headers["x-ratelimit-reset"].flatMap(Double.init), reset.isFinite, reset > 0 {
            return Date(timeIntervalSince1970: reset)
        }
        return now.addingTimeInterval(60)
    }

    // MARK: Finding links

    private nonisolated(unsafe) static let urlInText = try! NSRegularExpression(pattern: #"https?://[^\s<>"`]+"#, options: .caseInsensitive)
    private nonisolated static let closers: [Character: Character] = [")": "(", "]": "[", "}": "{"]

    /// A URL as written in text, without the punctuation that ends a sentence or the text after
    /// a bracket that closes around it; a bracket the URL opened itself, as in
    /// `/wiki/Mercury_(planet)`, stays.
    public nonisolated static func trimURL(_ url: String) -> String {
        var open: [Character: Int] = ["(": 0, "[": 0, "{": 0]
        var end = url.endIndex
        for index in url.indices {
            let char = url[index]
            if let count = open[char] {
                open[char] = count + 1
            } else if let opener = closers[char] {
                let count = open[opener] ?? 0
                open[opener] = count - 1
                if count == 0 {
                    end = index
                    break
                }
            }
        }
        var trimmed = url[..<end]
        while let last = trimmed.last, ".,:;!?*_~'".contains(last) { trimmed.removeLast() }
        return String(trimmed)
    }

    /// The `http(s)` URLs written in `text`, in order.
    public nonisolated static func findURLs(in text: String) -> [URL] {
        urlInText.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).flatMap { parse(trimURL(String(text[$0]))) }
        }
    }

    /// The link `value` names on a site in `sites`, or nil.
    public nonisolated static func previewLink(_ value: String, sites: [String: LinkSite] = LinkSites.all) -> PreviewLink? {
        guard let url = parse(value), let site = LinkSites.site(for: url, in: sites), let lookup = site.match(url) else { return nil }
        return PreviewLink(lookup: lookup, site: site)
    }

    /// The distinct previewable links in a message's text, in order, up to `maxPerMessage`,
    /// leaving out links in `skip`.
    public nonisolated static func findLinks(in text: String, skipping skip: [String] = [], sites: [String: LinkSite] = LinkSites.all) -> [PreviewLink] {
        var found: [PreviewLink] = []
        for url in findURLs(in: text) {
            if let link = previewLink(url.absoluteString, sites: sites), !found.contains(where: { $0.url == link.url }), !skip.contains(link.url) {
                found.append(link)
            }
            if found.count >= maxPerMessage { break }
        }
        return found
    }

    /// An `http(s)` URL with a host, as a browser reads one: scheme and host lowercased, dot
    /// segments resolved, and an empty path as `/`. A `%` without two hex digits after it, which a
    /// browser keeps and Foundation would read as `%25`, is no link.
    nonisolated static func parse(_ text: String) -> URL? {
        guard text.range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil, let url = URL(string: text), var components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        components.percentEncodedHost = components.percentEncodedHost?.lowercased()
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        return components.url?.standardized
    }
}

/// Fetches a site's API: no cookies, no credentials and no referrer, so the site learns no more
/// than the link it is asked about. An answer over 1 MB is no answer.
public enum LinkSiteFetch {
    public static let maxBytes = 1 << 20

    public static let live: DraftLinkPreviews.Fetch = { url, headers in
        var request = URLRequest(url: url, timeoutInterval: 10)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.expectedContentLength > Int64(maxBytes) { throw URLError(.dataLengthExceedsMaximum) }
        var body = Data()
        for try await byte in bytes {
            body.append(byte)
            if body.count > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
        }
        var named: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String { named[name.lowercased()] = value }
        }
        return DraftLinkPreviews.Response(status: http.statusCode, headers: named, body: body)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()
}
