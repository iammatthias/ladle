@testable import ApronKit
import Foundation
import XCTest

/// apron-web's `link-sites.test.ts`, case for case.
final class LinkSitesTests: XCTestCase {
    private func lookup(_ site: LinkSite, _ url: String) -> LinkLookup? {
        DraftLinkPreviews.parse(url).flatMap(site.match)
    }

    private func preview(_ site: LinkSite, _ url: String, _ data: JSONValue) -> OpenGraph? {
        lookup(site, url)?.preview(data)
    }

    private func og(_ site: String? = nil, _ title: String? = nil, _ description: String? = nil) -> OpenGraph {
        OpenGraph(siteName: site, title: title, description: description)
    }

    // MARK: Sites by host

    func testHostsAndTheirWWWLikeSubdomainsAndAnyLanguageOfWikipedia() {
        func name(_ url: String) -> String? { DraftLinkPreviews.parse(url).flatMap { LinkSites.site(for: $0)?.name } }
        XCTAssertEqual(name("https://github.com/a/b"), "GitHub")
        XCTAssertEqual(name("https://www.github.com/a/b"), "GitHub")
        XCTAssertEqual(name("https://m.youtube.com/watch?v=dQw4w9WgXcQ"), "YouTube")
        XCTAssertEqual(name("https://music.youtube.com/watch?v=dQw4w9WgXcQ"), "YouTube")
        XCTAssertEqual(name("https://mobile.twitter.com/jack/status/20"), "X")
        XCTAssertEqual(name("https://de.m.wikipedia.org/wiki/Ada_Lovelace"), "Wikipedia")
        XCTAssertNil(name("https://gist.github.com/a/b"))
        XCTAssertNil(name("https://github.com.evil.example/a/b"))
        XCTAssertNil(name("https://evilgithub.com/a/b"))
    }

    func testEachSiteAsksOnlyItsOwnAPIWhateverThePathHolds() {
        let apis: Set<String> = ["api.github.com", "www.youtube.com", "publish.x.com", "public.api.bsky.app", "en.wikipedia.org"]
        let hosts = ["github.com", "youtu.be", "www.youtube.com", "x.com", "bsky.app", "en.wikipedia.org"]
        let paths = ["/a/b", "/a/b/pull/1", "/watch?v=dQw4w9WgXcQ", "/a/status/1", "/profile/a.example/post/x", "/wiki/A"]
        let hostile = ["/..", "/%2e%2e", "/%2F%2Fevil.example", "/@evil.example", "/%3F", "/%23", "/..%2F..%2Fevil.example%2F"]
        var asked = 0
        for host in hosts {
            for path in paths {
                for bad in hostile {
                    for href in ["https://\(host)\(path)\(bad)", "https://\(host)\(bad)\(path)"] {
                        guard let url = DraftLinkPreviews.parse(href), let found = LinkSites.site(for: url)?.match(url) else { continue }
                        asked += 1
                        XCTAssertTrue(apis.contains(URL(string: found.api)?.host() ?? ""), "\(href) asks \(found.api)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(asked, 0)
    }

    // MARK: Text

    func testMarkdownBoilsDownToAShortLine() {
        XCTAssertEqual(LinkSites.excerpt("<!-- template -->\n## Summary\n\n- Moves the **Go** server to [its repo](https://x).\n```sh\nmake\n```"),
                       "Moves the Go server to its repo.")
        XCTAssertEqual(LinkSites.excerpt(String(repeating: "x", count: 300))?.unicodeScalars.count, 200)
        XCTAssertNil(LinkSites.excerpt(nil))
    }

    func testTextIsCutByCodePointNeverInsideAnEmoji() {
        XCTAssertEqual(LinkSites.clip(String(repeating: "x", count: 198) + "😀 tail"), String(repeating: "x", count: 198) + "😀…")
    }

    func testTheTextOfHTML() {
        XCTAssertEqual(LinkSites.htmlText(#"a<br>b <a href="x">c</a> &amp; &mdash; &#39;d&#x27; &#128512; &bogus;"#), "a b c & — 'd' 😀 &bogus;")
    }

    // MARK: GitHub

    func testGitHubReadsPullRequestsIssuesCommitsAndRepositoriesAndIgnoresOtherPages() {
        let pull = lookup(LinkSites.github, "https://github.com/shazow/apron/pull/60/files#diff")
        XCTAssertEqual(pull?.url, "https://github.com/shazow/apron/pull/60")
        XCTAssertEqual(pull?.api, "https://api.github.com/repos/shazow/apron/issues/60")
        XCTAssertEqual(pull?.fallback, og("GitHub · shazow/apron", "Pull request #60"))
        XCTAssertEqual(pull?.headers, ["Accept": "application/vnd.github+json"])
        let issue = lookup(LinkSites.github, "https://github.com/shazow/apron/issues/7")
        XCTAssertEqual(issue?.url, "https://github.com/shazow/apron/issues/7")
        XCTAssertEqual(issue?.fallback?.title, "Issue #7")
        let commit = lookup(LinkSites.github, "https://github.com/shazow/apron/commit/5B0CC30abc")
        XCTAssertEqual(commit?.api, "https://api.github.com/repos/shazow/apron/commits/5b0cc30abc")
        XCTAssertEqual(commit?.fallback?.title, "Commit 5b0cc30")
        let repo = lookup(LinkSites.github, "https://github.com/shazow/apron.git")
        XCTAssertEqual(repo?.url, "https://github.com/shazow/apron")
        XCTAssertEqual(repo?.api, "https://api.github.com/repos/shazow/apron")
        XCTAssertNotNil(lookup(LinkSites.github, "https://github.com/shazow/apron"))
        XCTAssertNil(lookup(LinkSites.github, "https://github.com/shazow/apron")?.fallback)
        XCTAssertNil(lookup(LinkSites.github, "https://github.com/shazow"))
        XCTAssertNil(lookup(LinkSites.github, "https://github.com/features/copilot"))
        XCTAssertNil(lookup(LinkSites.github, "https://github.com/shazow/apron/tree/main"))
        XCTAssertNil(lookup(LinkSites.github, "https://github.com/shazow/apron/pull/abc"))
    }

    func testGitHubDescribesPullRequestsAndIssuesWithTheirStateAndAuthorAndCommitsAndRepositories() {
        XCTAssertEqual(preview(LinkSites.github, "https://github.com/a/b/pull/60", [
            "title": "Remove the Go server", "state": "closed", "user": ["login": "shazow"], "body": "Now in its own repo.",
            "pull_request": ["merged_at": "2026-09-01T00:00:00Z"],
        ]), og("GitHub · a/b", "Remove the Go server", "Pull request #60 · Merged · by shazow — Now in its own repo."))
        XCTAssertEqual(preview(LinkSites.github, "https://github.com/a/b/issues/3", ["title": "Bug", "state": "closed", "state_reason": "not_planned", "body": ""])?.description,
                       "Issue #3 · Closed as not planned")
        XCTAssertNil(preview(LinkSites.github, "https://github.com/a/b/issues/3", [:]))
        XCTAssertEqual(preview(LinkSites.github, "https://github.com/a/b/commit/5b0cc30", ["commit": ["message": "Fix it\n\nBecause.", "author": ["name": "Ada"]]]),
                       og("GitHub · a/b", "Fix it", "Commit 5b0cc30 · by Ada — Because."))
        XCTAssertEqual(preview(LinkSites.github, "https://github.com/a/b", ["full_name": "a/b", "description": "A chat protocol", "language": "Go", "stargazers_count": 1234]),
                       og("GitHub", "a/b", "A chat protocol — Go · ★ 1,234"))
        XCTAssertEqual(preview(LinkSites.github, "https://github.com/a/b", ["full_name": "a/b", "description": "New", "stargazers_count": 0])?.description, "New")
    }

    // MARK: YouTube

    func testYouTubeReadsEveryFormOfAVideoLinkAsItsWatchPage() {
        let watch = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        for url in [watch, "https://youtu.be/dQw4w9WgXcQ?t=42", "https://m.youtube.com/watch?v=dQw4w9WgXcQ&list=x", "https://www.youtube.com/shorts/dQw4w9WgXcQ",
                    "https://www.youtube.com/live/dQw4w9WgXcQ", "https://www.youtube.com/embed/dQw4w9WgXcQ"] {
            let found = lookup(LinkSites.youtube, url)
            XCTAssertEqual(found?.url, watch, url)
            XCTAssertEqual(found?.api, "https://www.youtube.com/oembed?format=json&url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ", url)
            XCTAssertNil(found?.fallback, url)
        }
        XCTAssertNil(lookup(LinkSites.youtube, "https://www.youtube.com/@RickAstleyYT"))
        XCTAssertNil(lookup(LinkSites.youtube, "https://www.youtube.com/watch?v=short"))
    }

    func testYouTubeDescribesAVideoByItsTitleAndChannel() {
        let data: JSONValue = ["title": "Rick Astley - Never Gonna Give You Up", "author_name": "Rick Astley", "provider_name": "YouTube",
                               "thumbnail_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"]
        XCTAssertEqual(preview(LinkSites.youtube, "https://youtu.be/dQw4w9WgXcQ", data), og("YouTube · Rick Astley", "Rick Astley - Never Gonna Give You Up"))
        XCTAssertNil(preview(LinkSites.youtube, "https://youtu.be/dQw4w9WgXcQ", [:]))
    }

    // MARK: X

    func testXReadsPostsOnXAndTwitterAsXPosts() {
        for url in ["https://x.com/jack/status/20", "https://twitter.com/jack/status/20?s=20", "https://mobile.twitter.com/jack/status/20/photo/1"] {
            let found = lookup(LinkSites.x, url)
            XCTAssertEqual(found?.url, "https://x.com/jack/status/20", url)
            XCTAssertEqual(found?.api, "https://publish.x.com/oembed?omit_script=1&dnt=true&url=https%3A%2F%2Fx.com%2Fjack%2Fstatus%2F20", url)
            XCTAssertEqual(found?.fallback, og("X", "Post by @jack"), url)
        }
        XCTAssertNotNil(lookup(LinkSites.x, "https://x.com/i/status/20"))
        XCTAssertNil(lookup(LinkSites.x, "https://x.com/i/status/20")?.fallback)
        XCTAssertNil(lookup(LinkSites.x, "https://x.com/jack"))
        XCTAssertNil(lookup(LinkSites.x, "https://x.com/jack/likes"))
    }

    func testXDescribesAPostByItsAuthorDateAndTextFromTheOEmbedBlockquote() {
        let html = #"<blockquote class="twitter-tweet"><p lang="en" dir="ltr">just setting up my twttr &amp; <a href="https://t.co/x">more</a></p>&mdash; jack (@jack) <a href="https://x.com/jack/status/20?ref_src=twsrc%5Etfw">March 21, 2006</a></blockquote>"# + "\n\n"
        XCTAssertEqual(preview(LinkSites.x, "https://x.com/i/status/20", ["author_name": "jack", "author_url": "https://x.com/jack", "html": .string(html)]),
                       og("X · March 21, 2006", "jack (@jack)", "just setting up my twttr & more"))
        XCTAssertEqual(preview(LinkSites.x, "https://x.com/jack/status/20", [:]), og("X", "@jack"))
        XCTAssertNil(preview(LinkSites.x, "https://x.com/i/status/20", [:]))
    }

    // MARK: Bluesky

    func testBlueskyReadsPostsAndProfilesByHandleOrDID() {
        let post = lookup(LinkSites.bluesky, "https://bsky.app/profile/jay.bsky.team/post/3mymxa653fs27")
        XCTAssertEqual(post?.url, "https://bsky.app/profile/jay.bsky.team/post/3mymxa653fs27")
        XCTAssertEqual(post?.api, "https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?depth=0&parentHeight=0&uri=at%3A%2F%2Fjay.bsky.team%2Fapp.bsky.feed.post%2F3mymxa653fs27")
        XCTAssertEqual(post?.fallback, og("Bluesky", "Post by @jay.bsky.team"))
        XCTAssertNotNil(lookup(LinkSites.bluesky, "https://bsky.app/profile/did:plc:oky5czdrnfjpqslsw2a5iclo/post/3mymxa653fs27"))
        XCTAssertNil(lookup(LinkSites.bluesky, "https://bsky.app/profile/did:plc:oky5czdrnfjpqslsw2a5iclo/post/3mymxa653fs27")?.fallback)
        XCTAssertEqual(lookup(LinkSites.bluesky, "https://bsky.app/profile/Jay.Bsky.Team")?.url, "https://bsky.app/profile/jay.bsky.team")
        XCTAssertEqual(lookup(LinkSites.bluesky, "https://bsky.app/profile/did:plc:AbC/post/3mymxa653fs27")?.url, "https://bsky.app/profile/did:plc:AbC/post/3mymxa653fs27")
        XCTAssertEqual(lookup(LinkSites.bluesky, "https://bsky.app/profile/jay.bsky.team")?.api, "https://public.api.bsky.app/xrpc/app.bsky.actor.getProfile?actor=jay.bsky.team")
        XCTAssertNotNil(lookup(LinkSites.bluesky, "https://bsky.app/profile/jay.bsky.team"))
        XCTAssertNil(lookup(LinkSites.bluesky, "https://bsky.app/profile/jay.bsky.team")?.fallback)
        XCTAssertNil(lookup(LinkSites.bluesky, "https://bsky.app/profile/jay.bsky.team/lists/abc"))
        XCTAssertNil(lookup(LinkSites.bluesky, "https://bsky.app/search?q=x"))
    }

    func testBlueskyDescribesAPostByItsAuthorAndTextAndAProfileByItsBio() {
        let author: JSONValue = ["handle": "catsofyore.bsky.social", "displayName": "Cats of Yore"]
        XCTAssertEqual(preview(LinkSites.bluesky, "https://bsky.app/profile/catsofyore.bsky.social/post/3mymxa653fs27",
                               ["thread": ["post": ["author": author, "record": ["text": "Snow puff!\nPhoto from my collection."]]]]),
                       og("Bluesky", "Cats of Yore (@catsofyore.bsky.social)", "Snow puff! Photo from my collection."))
        XCTAssertNil(preview(LinkSites.bluesky, "https://bsky.app/profile/a.example/post/3mymxa653fs27",
                             ["thread": ["$type": "app.bsky.feed.defs#notFoundPost", "notFound": true]]))
        XCTAssertEqual(preview(LinkSites.bluesky, "https://bsky.app/profile/jay.bsky.team", ["handle": "jay.bsky.team", "displayName": "", "description": "Founder"]),
                       og("Bluesky", "@jay.bsky.team", "Founder"))
    }

    // MARK: Wikipedia

    func testWikipediaReadsArticlesInAnyLanguageWithTheirTitleFromTheURLUntilTheSummaryComes() {
        let mercury = lookup(LinkSites.wikipedia, "https://en.wikipedia.org/wiki/Mercury_(planet)#Orbit")
        XCTAssertEqual(mercury?.url, "https://en.wikipedia.org/wiki/Mercury_(planet)")
        XCTAssertEqual(mercury?.api, "https://en.wikipedia.org/api/rest_v1/page/summary/Mercury_(planet)")
        XCTAssertEqual(mercury?.fallback, og("Wikipedia", "Mercury (planet)"))
        let koln = lookup(LinkSites.wikipedia, "https://de.m.wikipedia.org/wiki/K%C3%B6ln")
        XCTAssertEqual(koln?.url, "https://de.wikipedia.org/wiki/K%C3%B6ln")
        XCTAssertEqual(koln?.fallback?.title, "Köln")
        for url in ["https://en.wikipedia.org/wiki/AC/DC", "https://en.wikipedia.org/wiki/AC%2FDC"] {
            let found = lookup(LinkSites.wikipedia, url)
            XCTAssertEqual(found?.url, "https://en.wikipedia.org/wiki/AC%2FDC", url)
            XCTAssertEqual(found?.api, "https://en.wikipedia.org/api/rest_v1/page/summary/AC%2FDC", url)
            XCTAssertEqual(found?.fallback?.title, "AC/DC", url)
        }
        XCTAssertNil(lookup(LinkSites.wikipedia, "https://en.wikipedia.org/wiki/Special:Random"))
        XCTAssertNil(lookup(LinkSites.wikipedia, "https://en.wikipedia.org/w/index.php?title=Ada"))
        XCTAssertNil(lookup(LinkSites.wikipedia, "https://www.wikipedia.org/wiki/Ada"))
        XCTAssertNil(lookup(LinkSites.wikipedia, "https://en.wikipedia.org/wiki/%E0%A4%A"))
    }

    func testWikipediaDescribesAnArticleByItsTitleAndOpeningSentences() {
        let data: JSONValue = ["type": "standard", "title": "Ada Lovelace", "description": "English mathematician (1815–1852)",
                               "extract": "Augusta Ada King, Countess of Lovelace, was an English mathematician."]
        XCTAssertEqual(preview(LinkSites.wikipedia, "https://en.wikipedia.org/wiki/Ada_Lovelace", data),
                       og("Wikipedia", "Ada Lovelace", "Augusta Ada King, Countess of Lovelace, was an English mathematician."))
        XCTAssertEqual(preview(LinkSites.wikipedia, "https://en.wikipedia.org/wiki/Ada_Lovelace", ["title": "Ada Lovelace", "description": "English mathematician"])?.description,
                       "English mathematician")
        XCTAssertNil(preview(LinkSites.wikipedia, "https://en.wikipedia.org/wiki/Ada_Lovelace", [:]))
    }
}
