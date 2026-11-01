@testable import ApronKit
import Foundation
import Synchronization
import XCTest

/// apron-web's `link-previews.test.ts`, case for case, with canned API answers.
@MainActor
final class DraftLinkPreviewsTests: XCTestCase {
    /// A fake API that answers from `answer` and records what was asked.
    private final class FakeAPI: Sendable {
        private let asked = Mutex<[(url: String, headers: [String: String])]>([])
        private let answer: @Sendable (URL) throws -> DraftLinkPreviews.Response

        init(_ answer: @escaping @Sendable (URL) throws -> DraftLinkPreviews.Response) { self.answer = answer }

        var calls: [String] { asked.withLock { $0.map(\.url) } }
        var headers: [[String: String]] { asked.withLock { $0.map(\.headers) } }

        var fetch: DraftLinkPreviews.Fetch {
            { url, headers in
                self.asked.withLock { $0.append((url.absoluteString, headers)) }
                return try self.answer(url)
            }
        }
    }

    private nonisolated static func json(_ body: JSONValue, _ status: Int = 200, _ headers: [String: String] = [:]) -> DraftLinkPreviews.Response {
        DraftLinkPreviews.Response(status: status, headers: headers, body: Data(body.serializedData()))
    }

    private final class Clock: Sendable {
        let time = Mutex(Date(timeIntervalSince1970: 1000))
        var now: @Sendable () -> Date { { self.time.withLock { $0 } } }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
    }

    private func link(_ url: String, _ og: OpenGraph) -> Embed {
        Embed(["kind": "link", "url": .string(url), "og": og.json])!
    }

    // MARK: Finding links

    func testURLsAreFoundWithoutThePunctuationOrBracketsAroundThemKeepingBracketsTheyOpen() {
        XCTAssertEqual(DraftLinkPreviews.trimURL("https://a.example/x)."), "https://a.example/x")
        XCTAssertEqual(DraftLinkPreviews.trimURL("https://en.wikipedia.org/wiki/Mercury_(planet)"), "https://en.wikipedia.org/wiki/Mercury_(planet)")
        XCTAssertEqual(DraftLinkPreviews.trimURL("https://en.wikipedia.org/wiki/Mercury_(planet)),"), "https://en.wikipedia.org/wiki/Mercury_(planet)")
        XCTAssertEqual(DraftLinkPreviews.trimURL("https://en.wikipedia.org/wiki/Hitchhiker's_Guide'"), "https://en.wikipedia.org/wiki/Hitchhiker's_Guide")
        XCTAssertEqual(DraftLinkPreviews.trimURL("https://a.example/x)and more"), "https://a.example/x")
        XCTAssertEqual(DraftLinkPreviews.trimURL("https://a.example/x](https://a.example/x)"), "https://a.example/x")
        XCTAssertEqual(DraftLinkPreviews.trimURL("https://a.example/" + String(repeating: ")", count: 100_000)), "https://a.example/")
        XCTAssertEqual(DraftLinkPreviews.findURLs(in: "see [this](https://a.example/b?c=1), <https://d.example> and **https://e.example/f**! ftp://g.example").map(\.absoluteString),
                       ["https://a.example/b?c=1", "https://d.example/", "https://e.example/f"])
    }

    func testOnlyLinksOnAKnownSiteThatItDescribesArePreviewed() {
        let pull = DraftLinkPreviews.previewLink("https://github.com/shazow/apron/pull/60/files#diff")
        XCTAssertEqual(pull?.url, "https://github.com/shazow/apron/pull/60")
        XCTAssertEqual(pull?.site.name, "GitHub")
        XCTAssertEqual(DraftLinkPreviews.previewLink("https://www.youtube.com/watch?v=dQw4w9WgXcQ")?.site.name, "YouTube")
        XCTAssertNil(DraftLinkPreviews.previewLink("https://example.com/a/b"))
        XCTAssertNil(DraftLinkPreviews.previewLink("https://github.com/shazow"))
        XCTAssertNil(DraftLinkPreviews.previewLink("javascript:alert(1)"))
        XCTAssertNil(DraftLinkPreviews.previewLink("not a url"))
    }

    func testDistinctPreviewableLinksAreFoundSkippingOthersUpToThree() {
        func urls(_ text: String, skipping skip: [String] = []) -> [String] { DraftLinkPreviews.findLinks(in: text, skipping: skip).map(\.url) }
        let text = "see https://github.com/a/b/pull/1, https://example.com/x and (https://github.com/a/b/issues/2). again https://github.com/a/b/pull/1 https://youtu.be/dQw4w9WgXcQ https://github.com/e/f"
        XCTAssertEqual(urls(text), ["https://github.com/a/b/pull/1", "https://github.com/a/b/issues/2", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
        XCTAssertEqual(urls("https://youtu.be/dQw4w9WgXcQ https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1").count, 1, "the same page linked two ways is one link")
        XCTAssertEqual(urls("https://x.com/Jack/status/20 https://x.com/jack/status/20 https://github.com/a/b/commit/ABCDEF1 https://github.com/a/b/commit/abcdef1").count, 2)
        XCTAssertEqual(urls("[https://github.com/a/b/pull/1](https://github.com/a/b/pull/1) (https://github.com/a/b/pull/2)and"),
                       ["https://github.com/a/b/pull/1", "https://github.com/a/b/pull/2"])
        XCTAssertEqual(urls(text, skipping: ["https://github.com/a/b/issues/2"]),
                       ["https://github.com/a/b/pull/1", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://github.com/e/f"])
    }

    // MARK: Fetching

    func testEachLinkIsFetchedOnceAndAttachesWhatItLearned() async {
        let api = FakeAPI { _ in Self.json(["title": "Remove the Go server", "state": "open", "user": ["login": "shazow"]]) }
        let previews = DraftLinkPreviews(fetch: api.fetch)
        let text = "look https://github.com/a/b/issues/60"
        XCTAssertEqual(previews.embeds(in: text), [link("https://github.com/a/b/issues/60", OpenGraph(siteName: "GitHub · a/b", title: "Issue #60"))])
        async let first: Void = previews.prefetch(text)
        async let second: Void = previews.prefetch(text)
        _ = await (first, second)
        await previews.prefetch(text)
        XCTAssertEqual(api.calls, ["https://api.github.com/repos/a/b/issues/60"])
        XCTAssertEqual(api.headers, [["Accept": "application/vnd.github+json"]])
        XCTAssertEqual(previews.embeds(in: text).first?.og,
                       OpenGraph(siteName: "GitHub · a/b", title: "Remove the Go server", description: "Issue #60 · Open · by shazow"))
    }

    func testPrivateLinksAndFailedRequestsFallBackToTheURLAndAnUnknownRepositoryAttachesNothing() async {
        let api = FakeAPI { _ in Self.json(["message": "Not Found"], 404) }
        let previews = DraftLinkPreviews(fetch: api.fetch)
        await previews.prefetch("https://github.com/a/b/pull/1 https://github.com/c/d")
        XCTAssertEqual(previews.embeds(in: "https://github.com/a/b/pull/1 https://github.com/c/d"),
                       [link("https://github.com/a/b/pull/1", OpenGraph(siteName: "GitHub · a/b", title: "Pull request #1"))])
        await previews.prefetch("https://github.com/a/b/pull/1")
        XCTAssertEqual(api.calls.count, 2)
        let offline = DraftLinkPreviews(fetch: { _, _ in throw URLError(.notConnectedToInternet) })
        await offline.prefetch("https://github.com/a/b/pull/1")
        XCTAssertEqual(offline.embeds(in: "https://github.com/a/b/pull/1").first?.og?.title, "Pull request #1")
    }

    func testARateLimitedSiteIsNotAskedUntilTheLimitResets() async {
        let clock = Clock()
        let reset = String(Int(clock.now().timeIntervalSince1970) + 60)
        let api = FakeAPI { _ in Self.json(["message": "rate limited"], 403, ["x-ratelimit-reset": reset]) }
        let previews = DraftLinkPreviews(fetch: api.fetch, now: clock.now)
        await previews.prefetch("https://github.com/a/b/pull/1")
        await previews.prefetch("https://github.com/a/b/pull/2")
        XCTAssertEqual(api.calls.count, 1)
        clock.advance(61)
        await previews.prefetch("https://github.com/a/b/pull/1")
        XCTAssertEqual(api.calls.count, 2)
    }

    func testARateLimitedSiteIsHeldForItsRetryAfterWithoutHoldingTheOthers() async {
        let clock = Clock()
        let api = FakeAPI { url in
            url.absoluteString.contains("youtube") ? Self.json([:], 429, ["retry-after": "120"]) : Self.json(["title": "T", "state": "open"])
        }
        let previews = DraftLinkPreviews(fetch: api.fetch, now: clock.now)
        await previews.prefetch("https://youtu.be/dQw4w9WgXcQ")
        await previews.prefetch("https://youtu.be/aaaaaaaaaaa https://github.com/a/b/pull/1")
        XCTAssertEqual(api.calls.count, 2)
        clock.advance(121)
        await previews.prefetch("https://youtu.be/aaaaaaaaaaa")
        XCTAssertEqual(api.calls.count, 3)
    }

    func testTheStatusesASiteNamesAsMissingAreRememberedAndOtherFailuresAskedAgain() async {
        let site = LinkSite(name: "Test", missing: [400]) { url in
            LinkLookup(url: url.absoluteString, api: "https://api.test\(url.path())", preview: { _ in nil }, fallback: OpenGraph(title: "From the URL"))
        }
        let statuses = ["/gone": 400, "/broken": 500]
        let api = FakeAPI { url in Self.json([:], statuses[url.path()] ?? 200) }
        let previews = DraftLinkPreviews(fetch: api.fetch, sites: ["test.example": site])
        await previews.prefetch("https://test.example/gone https://test.example/broken")
        await previews.prefetch("https://test.example/gone https://test.example/broken")
        XCTAssertEqual(api.calls, ["https://api.test/gone", "https://api.test/broken", "https://api.test/broken"])
        XCTAssertEqual(previews.embeds(in: "https://test.example/gone"), [link("https://test.example/gone", OpenGraph(title: "From the URL"))])
    }

    func testDismissedLinksAreLeftOutLettingLaterOnesInUnderTheCapAndArrivalsRedrawTheComposer() async {
        let previews = DraftLinkPreviews(fetch: { _, _ in Self.json(["title": "T", "state": "open"]) })
        let text = "https://github.com/a/b/pull/1 https://github.com/a/b/pull/2 https://github.com/a/b/pull/3 https://github.com/a/b/pull/4"
        XCTAssertEqual(previews.embeds(in: text, dismissed: ["https://github.com/a/b/pull/2"]).compactMap(\.url?.absoluteString),
                       ["https://github.com/a/b/pull/1", "https://github.com/a/b/pull/3", "https://github.com/a/b/pull/4"])
        let changed = Mutex(false)
        withObservationTracking { _ = previews.embeds(in: "https://github.com/a/b/pull/1") } onChange: { changed.withLock { $0 = true } }
        await previews.prefetch("https://github.com/a/b/pull/1")
        XCTAssertTrue(changed.withLock { $0 }, "an arrived preview redraws what read the embeds")
        XCTAssertEqual(previews.embeds(in: "https://github.com/a/b/pull/1").first?.og?.description, "Issue #1 · Open")
    }
}
