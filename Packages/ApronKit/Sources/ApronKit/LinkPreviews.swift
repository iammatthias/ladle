import CryptoKit
import Darwin
import Foundation

/// A preview this device fetched for a link the server did not describe: the page's title, its
/// site, a small JPEG of its image, and the direct video URL the page names, if any.
public struct LinkPreview: Codable, Hashable, Sendable {
    public var title: String
    public var site: String
    public var image: Data?
    public var video: URL?

    public init(title: String, site: String, image: Data? = nil, video: URL? = nil) {
        self.title = title
        self.site = site
        self.image = image
        self.video = video
    }

    /// The video to play inline: the page's own, under the rules that let this device fetch the
    /// page's image (`LinkPreviews.mayFetch`). Nil keeps the image.
    public var playableVideo: URL? { video.flatMap { LinkPreviews.mayFetch($0) ? $0 : nil } }
}

extension MessageSnapshot {
    /// The link this device may fetch a preview for: the first one it may fetch among the
    /// message's first three links (its text's links, then `link` embeds without `og`). Nil once
    /// any embed on the message carries the server's `og`, which then is the preview.
    public var unfurlURL: URL? {
        let embeds = embedList
        guard !embeds.contains(where: { $0.og != nil && $0.upload == nil }) else { return nil }
        var seen = Set<URL>()
        let links = (MessageText.links(body) + embeds.filter { $0.kind == "link" }.compactMap(\.url))
            .filter { seen.insert($0).inserted }
        return links.prefix(3).first(where: LinkPreviews.mayFetch)
    }
}

/// Link previews fetched on this device, cached in memory and as one JSON file per link, so a
/// scrolling timeline asks each site once per `ttl`. A failed or empty fetch is cached too, for
/// `failureTTL`. At most `maxConcurrent` fetches run at once; a caller cancelled while queued
/// gives up its place.
@MainActor
public final class LinkPreviews {
    public typealias Fetch = @Sendable (URL) async -> LinkPreview?

    public static let ttl: TimeInterval = 7 * 86_400
    public static let failureTTL: TimeInterval = 86_400
    public static let maxConcurrent = 3

    struct Entry: Codable, Sendable {
        var preview: LinkPreview?
        var fetchedAt: Date
    }

    private let directory: URL?
    private let now: @Sendable () -> Date
    private let fetch: Fetch
    private var memory: [String: Entry] = [:]
    private var inFlight: [String: Task<LinkPreview?, Never>] = [:]
    private var running = 0
    private var queue: [(id: UUID, resume: CheckedContinuation<Bool, Never>)] = []

    /// `directory` nil keeps the cache in memory only.
    public init(directory: URL?, now: @escaping @Sendable () -> Date = Date.init, fetch: @escaping Fetch) {
        self.directory = directory
        self.now = now
        self.fetch = fetch
    }

    /// The preview already in memory and fresh, without waiting.
    public func cached(_ url: URL) -> LinkPreview? {
        fresh(Self.key(url))?.preview
    }

    /// The preview for `url`: from the cache when fresh, else fetched.
    public func preview(for url: URL) async -> LinkPreview? {
        let key = Self.key(url)
        if let entry = fresh(key) { return entry.preview }
        if let entry = await read(key), isFresh(entry) {
            memory[key] = entry
            return entry.preview
        }
        if let running = inFlight[key] { return await running.value }
        guard await acquire() else { return nil }
        defer { release() }
        // Another caller may have fetched it while this one waited for a slot.
        if let entry = fresh(key) { return entry.preview }
        if let running = inFlight[key] { return await running.value }
        let fetch = fetch
        let task = Task { await fetch(url) }
        inFlight[key] = task
        let preview = await task.value
        inFlight[key] = nil
        let entry = Entry(preview: preview, fetchedAt: now())
        if memory.count >= 512 { memory.removeAll() }
        memory[key] = entry
        write(entry, key)
        return preview
    }

    private func fresh(_ key: String) -> Entry? {
        memory[key].flatMap { isFresh($0) ? $0 : nil }
    }

    private func isFresh(_ entry: Entry) -> Bool {
        now().timeIntervalSince(entry.fetchedAt) < (entry.preview == nil ? Self.failureTTL : Self.ttl)
    }

    private func read(_ key: String) async -> Entry? {
        guard let file = directory?.appending(path: key + ".json") else { return nil }
        return await Task.detached {
            (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
        }.value
    }

    private func write(_ entry: Entry, _ key: String) {
        guard let directory else { return }
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(entry).write(to: directory.appending(path: key + ".json"), options: .atomic)
        }
    }

    private func acquire() async -> Bool {
        if running < Self.maxConcurrent {
            running += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { queue.append((id, $0)) }
        } onCancel: {
            Task { @MainActor in self.leaveQueue(id) }
        }
    }

    /// Hands the slot to the next caller in line, or frees it.
    private func release() {
        if queue.isEmpty {
            running -= 1
        } else {
            queue.removeFirst().resume.resume(returning: true)
        }
    }

    private func leaveQueue(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue.remove(at: index).resume.resume(returning: false)
    }

    /// The cache key: a hash of the URL without its fragment, scheme and host lowercased.
    nonisolated static func key(_ url: URL) -> String {
        var text = url.absoluteString
        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.fragment = nil
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            text = components.string ?? text
        }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether this device may fetch `url`: `http` or `https` on a public host name or address.
    /// Apron's own links open in the app (`ApronLink`) instead. `localhost`, `.local` and single-label names,
    /// and loopback, private, link-local and other non-public address literals are refused,
    /// because the fetch would reach into the reader's own network. A public name that resolves
    /// or redirects to such an address is not caught here.
    public nonisolated static func mayFetch(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") { return isPublicIPv6(host) }
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 { return isPublicIPv4(UInt32(bigEndian: v4.s_addr)) }
        guard host.contains("."), host != "link.apron.chat" else { return false }
        return !(host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local"))
    }

    private nonisolated static func isPublicIPv4(_ address: UInt32) -> Bool {
        let refused: [(UInt32, Int)] = [
            (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8), (0xA9FE_0000, 16),
            (0xAC10_0000, 12), (0xC000_0000, 24), (0xC0A8_0000, 16), (0xC612_0000, 15), (0xE000_0000, 3),
        ]
        return !refused.contains { network, bits in address >> (32 - bits) == network >> (32 - bits) }
    }

    private nonisolated static func isPublicIPv6(_ host: String) -> Bool {
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0 ..< 10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isPublicIPv4(bytes[12 ..< 16].reduce(0) { $0 << 8 | UInt32($1) })
        }
        if bytes[0 ..< 15].allSatisfy({ $0 == 0 }) { return false }
        return !(bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) || bytes[0] == 0xFF)
    }
}
