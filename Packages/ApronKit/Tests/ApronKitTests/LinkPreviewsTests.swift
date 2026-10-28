@testable import ApronKit
import Foundation
import XCTest

@MainActor
final class LinkPreviewsTests: XCTestCase {
    private func message(_ text: String, embeds: [JSONValue] = []) throws -> MessageSnapshot {
        let params: JSONValue = [
            "body": ["text": .string(text), "embeds": .array(embeds)],
            "from": ["name": "ada", "user_id": "ada"], "log_id": "10", "message_id": "10", "room_id": "general",
        ]
        return try XCTUnwrap(Records(messageParams: params).messages.first)
    }

    func testTheFirstLinkTheDeviceMayFetchIsUnfurled() throws {
        XCTAssertEqual(try message("see https://a.example/1 and https://b.example/2").unfurlURL?.absoluteString, "https://a.example/1")
        XCTAssertEqual(try message("apron:?room=ops then https://link.apron.chat/#server=x then https://b.example/2").unfurlURL?.absoluteString,
                       "https://b.example/2")
        XCTAssertEqual(try message("http://192.168.1.1/admin or http://localhost:3000 or https://c.example").unfurlURL?.absoluteString,
                       "https://c.example")
        XCTAssertNil(try message("http://10.0.0.1 http://127.0.0.1 http://[::1]/ https://d.example").unfurlURL,
                     "only the first three links are considered")
        XCTAssertNil(try message("no links, mailto:ada@example.com").unfurlURL)
    }

    func testALinkEmbedWithoutOgIsALinkToUnfurl() throws {
        let bare: JSONValue = ["kind": "link", "url": "https://git.example/pull/42"]
        XCTAssertEqual(try message("look", embeds: [bare]).unfurlURL?.absoluteString, "https://git.example/pull/42")
        let poll: JSONValue = ["kind": "poll", "url": "https://poll.example/p/7"]
        XCTAssertNil(try message("vote", embeds: [poll]).unfurlURL)
    }

    func testTheServersOgWins() throws {
        let described: JSONValue = ["kind": "link", "url": "https://a.example/1", "og": ["title": "A"]]
        XCTAssertEqual(try message("see https://a.example/1").unfurlURL?.absoluteString, "https://a.example/1")
        XCTAssertNil(try message("see https://a.example/1", embeds: [described]).unfurlURL)
        let upload: JSONValue = ["kind": "upload", "url": "https://home.example/f", "og": ["image": ["url": "https://home.example/f"]]]
        XCTAssertEqual(try message("see https://a.example/1", embeds: [upload]).unfurlURL?.absoluteString, "https://a.example/1",
                       "an upload's og describes the file, not the link")
    }

    func testHostsTheDeviceMayFetch() {
        let allowed = ["https://example.com/x", "http://sub.example.org:8080/", "https://8.8.8.8/", "https://[2001:4860::8888]/",
                       "https://172.32.0.1/", "HTTPS://Example.COM"]
        let refused = ["apron:?room=ops", "ftp://example.com/", "https://link.apron.chat/#server=x", "https://LINK.apron.chat./",
                       "http://localhost/", "http://api.localhost/", "http://printer.local/", "http://router/",
                       "http://127.0.0.1/", "http://127.1/", "http://2130706433/", "http://0x7f.1/", "http://10.1.2.3/",
                       "http://172.16.0.1/", "http://172.31.255.255/", "http://192.168.0.10/", "http://169.254.169.254/latest",
                       "http://100.64.0.1/", "http://0.0.0.0/", "http://[::1]/", "http://[::]/", "http://[fe80::1]/",
                       "http://[fd00::1]/", "http://[::ffff:192.168.0.1]/", "http://[::ffff:7f00:1]/"]
        for text in allowed { XCTAssertTrue(LinkPreviews.mayFetch(URL(string: text)!), text) }
        for text in refused { XCTAssertFalse(LinkPreviews.mayFetch(URL(string: text)!), text) }
    }

    func testTheCacheKeyIgnoresTheFragmentAndCase() {
        let key = LinkPreviews.key(URL(string: "https://example.com/Page?q=1")!)
        XCTAssertEqual(LinkPreviews.key(URL(string: "HTTPS://EXAMPLE.com/Page?q=1#top")!), key)
        XCTAssertNotEqual(LinkPreviews.key(URL(string: "https://example.com/page?q=1")!), key)
    }

    func testAPreviewIsFetchedOncePerTTL() async {
        let clock = Clock()
        let fetches = Counter()
        let previews = LinkPreviews(directory: nil, now: clock.now) { _ in
            await fetches.add()
            return LinkPreview(title: "Example", site: "example.com")
        }
        let url = URL(string: "https://example.com/a")!
        XCTAssertNil(previews.cached(url))
        let first = await previews.preview(for: url)
        XCTAssertEqual(first, LinkPreview(title: "Example", site: "example.com"))
        XCTAssertEqual(previews.cached(url), first)
        clock.advance(LinkPreviews.ttl - 1)
        _ = await previews.preview(for: url)
        let afterOne = await fetches.count
        XCTAssertEqual(afterOne, 1)
        clock.advance(1)
        XCTAssertNil(previews.cached(url))
        _ = await previews.preview(for: url)
        let afterTwo = await fetches.count
        XCTAssertEqual(afterTwo, 2)
    }

    func testAFailedFetchIsRememberedForTheFailureTTL() async {
        let clock = Clock()
        let fetches = Counter()
        let previews = LinkPreviews(directory: nil, now: clock.now) { _ in
            await fetches.add()
            return nil
        }
        let url = URL(string: "https://example.com/gone")!
        let first = await previews.preview(for: url)
        XCTAssertNil(first)
        clock.advance(LinkPreviews.failureTTL - 1)
        _ = await previews.preview(for: url)
        let afterOne = await fetches.count
        XCTAssertEqual(afterOne, 1)
        clock.advance(1)
        _ = await previews.preview(for: url)
        let afterTwo = await fetches.count
        XCTAssertEqual(afterTwo, 2)
    }

    func testTheDiskCacheOutlivesTheProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "link-previews-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let url = URL(string: "https://example.com/kept")!
        let saved = LinkPreview(title: "Kept", site: "example.com", image: Data([0xFF, 0xD8]))
        let first = LinkPreviews(directory: directory, now: clock.now) { _ in saved }
        _ = await first.preview(for: url)
        let file = directory.appending(path: LinkPreviews.key(url) + ".json")
        for _ in 0 ..< 100 where !FileManager.default.fileExists(atPath: file.path()) { try await Task.sleep(for: .milliseconds(10)) }

        let second = LinkPreviews(directory: directory, now: clock.now) { _ in
            XCTFail("a fresh disk entry is not fetched again")
            return nil
        }
        let loaded = await second.preview(for: url)
        XCTAssertEqual(loaded, saved)

        clock.advance(LinkPreviews.ttl)
        let third = LinkPreviews(directory: directory, now: clock.now) { _ in LinkPreview(title: "New", site: "example.com") }
        let refreshed = await third.preview(for: url)
        XCTAssertEqual(refreshed?.title, "New")
    }

    func testAtMostThreeFetchesRunAtOnce() async {
        let gate = Gate()
        let previews = LinkPreviews(directory: nil) { url in
            await gate.enter()
            return LinkPreview(title: url.lastPathComponent, site: "example.com")
        }
        let tasks = (1 ... 5).map { n in Task { await previews.preview(for: URL(string: "https://example.com/\(n)")!)?.title } }
        for _ in 0 ..< 200 where await gate.inside < 3 { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        let inside = await gate.inside
        XCTAssertEqual(inside, 3)
        await gate.open()
        var finished: [String?] = []
        for task in tasks { finished.append(await task.value) }
        XCTAssertEqual(finished, ["1", "2", "3", "4", "5"])
        let peak = await gate.peak
        XCTAssertEqual(peak, 3)
    }

    func testACallerCancelledWhileQueuedGivesUpItsPlace() async {
        let gate = Gate()
        let fetched = Counter()
        let previews = LinkPreviews(directory: nil) { _ in
            await fetched.add()
            await gate.enter()
            return LinkPreview(title: "t", site: "example.com")
        }
        let holders = (1 ... 3).map { n in Task { await previews.preview(for: URL(string: "https://example.com/\(n)")!) } }
        for _ in 0 ..< 200 where await gate.inside < 3 { try? await Task.sleep(for: .milliseconds(5)) }
        let queued = Task { await previews.preview(for: URL(string: "https://example.com/queued")!) }
        try? await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        let result = await queued.value
        XCTAssertNil(result)
        await gate.open()
        for holder in holders { _ = await holder.value }
        let count = await fetched.count
        XCTAssertEqual(count, 3)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: @Sendable () -> Date { { [self] in lock.withLock { current } } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private actor Counter {
    var count = 0
    func add() { count += 1 }
}

/// Holds every fetch until `open`, counting how many wait at once.
private actor Gate {
    var inside = 0
    var peak = 0
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        inside += 1
        peak = max(peak, inside)
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
        inside -= 1
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}
