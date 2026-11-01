import Foundation
import Synchronization

/// How a site describes one of its links, as apron-web's `Lookup`: what to ask its public API,
/// and what the answer says.
public struct LinkLookup: Sendable {
    /// The link as its preview names it: one address per page, so the same page linked two ways
    /// is one preview.
    public var url: String
    /// The API request that describes it.
    public var api: String
    public var headers: [String: String] = [:]
    /// The `og` for the API's answer, or nil when it describes nothing.
    public var preview: @Sendable (JSONValue) -> OpenGraph?
    /// What the URL alone says, sent until the answer arrives; nil when that is too little.
    public var fallback: OpenGraph?
}

/// A site whose links the sender describes, as apron-web's `Site`.
public struct LinkSite: Sendable {
    /// Names the site, which is asked and rate limited apart from the others.
    public var name: String
    /// Statuses that say the link has nothing to describe, remembered so it isn't asked again.
    public var missing: [Int] = [404]
    /// Statuses that say requests are being limited, holding further ones until the limit resets.
    public var limited: [Int] = [429]
    /// Any subdomain of its host is this site too, not only `www.` and its like.
    public var subdomains = false
    /// The lookup for a URL, or nil for a page this site doesn't describe.
    public var match: @Sendable (URL) -> LinkLookup?
}

/// apron-web's `link-sites.ts`: GitHub, YouTube, X, Bluesky and Wikipedia, each described from a
/// public API that needs no account.
public enum LinkSites {
    static let descriptionMax = 200

    /// The sites with previews, by host; `site(for:)` finds their subdomains.
    public static let all: [String: LinkSite] = [
        "github.com": github,
        "youtube.com": youtube,
        "youtu.be": youtube,
        "x.com": x,
        "twitter.com": x,
        "bsky.app": bluesky,
        "wikipedia.org": wikipedia,
    ]

    /// Subdomains that are the same site as their parent; others (such as gist.github.com) are not.
    private static let sameSite: Set<String> = ["www", "m", "mobile", "music"]

    /// The site that previews `url`, if any: the one its host names, or its parent domain's.
    public static func site(for url: URL, in sites: [String: LinkSite] = all) -> LinkSite? {
        let labels = url.hostname.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count > 1 else { return nil }
        for i in 0 ..< labels.count - 1 {
            if let site = sites[labels[i...].joined(separator: ".")] {
                return site.subdomains || labels[..<i].allSatisfy(sameSite.contains) ? site : nil
            }
        }
        return nil
    }

    // MARK: Text

    /// Text as one line, cut to fit a card by code point, so an emoji isn't cut in half.
    public static func clip(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = replacing(#"\s+"#, in: text, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let scalars = Array(line.unicodeScalars)
        guard scalars.count > descriptionMax else { return line }
        var cut = String(String.UnicodeScalarView(scalars.prefix(descriptionMax - 1)))
        while let last = cut.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) { cut.unicodeScalars.removeLast() }
        return cut + "…"
    }

    /// Markdown reduced to a line of plain text, cut to fit a card; headings and HTML comments
    /// (as in PR templates) are left out.
    public static func excerpt(_ markdown: String?) -> String? {
        guard var text = markdown else { return nil }
        text = replacing(#"<!--[\s\S]*?(-->|\z)"#, in: text, with: " ")
        text = replacing(#"```[\s\S]*?(```|\z)"#, in: text, with: " ")
        text = replacing(#"!\[[^\]]*\]\([^)]*\)"#, in: text, with: " ")
        text = replacing(#"\[([^\]]*)\]\([^)]*\)"#, in: text, with: "$1")
        text = replacing(#"<[^>]+>"#, in: text, with: " ")
        text = replacing(#"^\s{0,3}#{1,6}\s.*$"#, in: text, with: " ", options: .anchorsMatchLines)
        text = replacing(#"^\s{0,3}(>|[-*+]|\d+\.)\s+"#, in: text, with: "", options: .anchorsMatchLines)
        text = replacing(#"[`*_~]+"#, in: text, with: "")
        return clip(text)
    }

    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "mdash": "—", "ndash": "–", "hellip": "…",
    ]

    /// An HTML fragment's text: tags dropped, `<br>` as a space, entities decoded.
    public static func htmlText(_ html: String) -> String {
        var text = replacing(#"<br\s*/?>"#, in: html, with: " ", options: .caseInsensitive)
        text = replacing(#"<[^>]*>"#, in: text, with: "")
        return replacing(#"&(#x[0-9a-f]+|#\d+|[a-z]+);"#, in: text, options: .caseInsensitive) { groups in
            let entity = groups[0], name = groups[1]
            guard name.hasPrefix("#") else { return entities[name.lowercased()] ?? entity }
            let hex = name.dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
            let code = hex ? UInt32(name.dropFirst(2), radix: 16) : UInt32(name.dropFirst())
            guard let code, code > 0, code <= 0x10FFFF, let scalar = Unicode.Scalar(code) else { return entity }
            return String(Character(scalar))
        }
    }

    // MARK: GitHub

    private static let githubName = #"^[A-Za-z0-9_.-]+$"#
    /// First path segments that are GitHub's own pages, not owners.
    private static let githubReserved: Set<String> = [
        "about", "apps", "blog", "collections", "contact", "customer-stories", "enterprise", "events", "explore", "features",
        "login", "marketplace", "new", "notifications", "orgs", "organizations", "pricing", "pulls", "issues", "search",
        "security", "settings", "site", "sponsors", "topics", "trending",
    ]

    /// GitHub pull requests, issues, commits and repositories, from its REST API. Unauthenticated
    /// calls are limited per IP, and an exhausted limit answers 403.
    public static let github = LinkSite(name: "GitHub", limited: [403, 429]) { url in
        let parts = url.pathParts
        guard parts.count >= 2 else { return nil }
        let owner = parts[0], repo = parts[1]
        let section = parts.count > 2 ? parts[2] : nil, id = parts.count > 3 ? parts[3] : nil
        guard matches(githubName, owner), matches(githubName, repo), !githubReserved.contains(owner.lowercased()) else { return nil }
        let name = repo.hasSuffix(".git") ? String(repo.dropLast(4)) : repo
        let base = "https://github.com/\(owner)/\(name)"
        let api = "https://api.github.com/repos/\(owner)/\(name)"
        let headers = ["Accept": "application/vnd.github+json"]
        let siteName = "GitHub · \(owner)/\(name)"
        guard let section else { return LinkLookup(url: base, api: api, headers: headers, preview: githubRepo) }
        if section == "pull" || section == "issues", let id, matches(#"^\d+$"#, id) {
            let label = "\(section == "pull" ? "Pull request" : "Issue") #\(id)"
            return LinkLookup(url: "\(base)/\(section)/\(id)", api: "\(api)/issues/\(id)", headers: headers,
                              preview: { githubIssue(siteName, id, $0) }, fallback: OpenGraph(siteName: siteName, title: label))
        }
        if section == "commit", let id, matches(#"^[0-9a-f]{7,40}$"#, id, options: .caseInsensitive) {
            let sha = id.lowercased()
            return LinkLookup(url: "\(base)/commit/\(sha)", api: "\(api)/commits/\(sha)", headers: headers,
                              preview: { githubCommit(siteName, sha, $0) },
                              fallback: OpenGraph(siteName: siteName, title: "Commit \(sha.prefix(7))"))
        }
        return nil
    }

    private static func githubIssue(_ siteName: String, _ number: String, _ data: JSONValue) -> OpenGraph? {
        guard let title = str(data["title"]) else { return nil }
        let pull = record(data["pull_request"])
        let isPull = !(pull.objectValue ?? [:]).isEmpty
        let closed = data["state"]?.stringValue == "closed"
        let state = isPull
            ? (str(pull["merged_at"]) != nil ? "Merged" : closed ? "Closed" : truthy(data["draft"]) ? "Draft" : "Open")
            : closed ? (data["state_reason"]?.stringValue == "not_planned" ? "Closed as not planned" : "Closed") : "Open"
        let author = str(record(data["user"])["login"])
        let summary = ["\(isPull ? "Pull request" : "Issue") #\(number)", state, author.map { "by \($0)" }].compactMap(\.self).joined(separator: " · ")
        let body = excerpt(data["body"]?.stringValue)
        return OpenGraph(siteName: siteName, title: title, description: body.map { "\(summary) — \($0)" } ?? summary)
    }

    private static func githubCommit(_ siteName: String, _ sha: String, _ data: JSONValue) -> OpenGraph? {
        let commit = record(data["commit"])
        guard let message = str(commit["message"]) else { return nil }
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        let subject = String(lines[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let author = str(record(data["author"])["login"]) ?? str(record(commit["author"])["name"])
        let summary = ["Commit \(sha.prefix(7))", author.map { "by \($0)" }].compactMap(\.self).joined(separator: " · ")
        let body = excerpt(lines.dropFirst().joined(separator: "\n"))
        return OpenGraph(siteName: siteName, title: subject, description: body.map { "\(summary) — \($0)" } ?? summary)
    }

    private static func githubRepo(_ data: JSONValue) -> OpenGraph? {
        guard let name = str(data["full_name"]) else { return nil }
        let count = data["stargazers_count"]?.doubleValue ?? 0
        let stars = count > 0 ? "★ \(count.formatted(.number.locale(Locale(identifier: "en_US"))))" : nil
        let details = [str(data["language"]), stars].compactMap(\.self).joined(separator: " · ")
        let description = [excerpt(data["description"]?.stringValue), details.isEmpty ? nil : details].compactMap(\.self).joined(separator: " — ")
        return OpenGraph(siteName: "GitHub", title: name, description: description.isEmpty ? nil : description)
    }

    // MARK: YouTube

    /// YouTube videos, from its oEmbed endpoint: the title and channel. A video that is private,
    /// removed or not embeddable answers 401, 403 or 404, and a malformed one 400.
    public static let youtube = LinkSite(name: "YouTube", missing: [400, 401, 403, 404]) { url in
        let parts = url.pathParts
        let first = parts.first, second = parts.count > 1 ? parts[1] : nil
        let id: String? = url.hostname == "youtu.be" ? first
            : first == "watch" ? url.query(named: "v")
            : first == "shorts" || first == "live" || first == "embed" ? second
            : nil
        guard let id, matches(#"^[A-Za-z0-9_-]{11}$"#, id) else { return nil }
        let watch = "https://www.youtube.com/watch?v=\(id)"
        return LinkLookup(url: watch, api: "https://www.youtube.com/oembed?format=json&url=\(encodeURIComponent(watch))") { data in
            guard let title = str(data["title"]) else { return nil }
            let channel = str(data["author_name"])
            return OpenGraph(siteName: channel.map { "YouTube · \($0)" } ?? "YouTube", title: title)
        }
    }

    // MARK: X

    /// Posts on X, from its oEmbed endpoint, whose answer carries the post only as an HTML
    /// blockquote: the text, then the author and date.
    public static let x = LinkSite(name: "X", missing: [400, 403, 404]) { url in
        let parts = url.pathParts
        guard parts.count >= 3 else { return nil }
        let user = parts[0], section = parts[1], id = parts[2]
        guard matches(#"^[A-Za-z0-9_]{1,15}$"#, user), section == "status", matches(#"^\d{1,20}$"#, id) else { return nil }
        // Handles are case-insensitive, so one post is one preview however it's written.
        let post = "https://x.com/\(user.lowercased())/status/\(id)"
        // `/i/status/<id>` names no author.
        let known = user.lowercased() != "i"
        return LinkLookup(url: post, api: "https://publish.x.com/oembed?omit_script=1&dnt=true&url=\(encodeURIComponent(post))", preview: { data in
            let author = str(data["author_name"])
            let handle = str(data["author_url"]).flatMap { firstGroup(#"/([A-Za-z0-9_]{1,15})$"#, in: $0) } ?? (known ? user : nil)
            guard author != nil || handle != nil else { return nil }
            let html = str(data["html"]) ?? ""
            let text = clip(htmlText(firstGroup(#"<p\b[^>]*>([\s\S]*?)</p>"#, in: html, options: .caseInsensitive) ?? ""))
            let date = clip(htmlText(lastGroup(#"<a\b[^>]*>([^<]*)</a>"#, in: html, options: .caseInsensitive) ?? ""))
            let title = if let author, let handle { "\(author) (@\(handle))" } else { author ?? "@\(handle ?? "")" }
            return OpenGraph(siteName: date.map { "X · \($0)" } ?? "X", title: title, description: text)
        }, fallback: known ? OpenGraph(siteName: "X", title: "Post by @\(user)") : nil)
    }

    // MARK: Bluesky

    private static let blueskyAPI = "https://public.api.bsky.app/xrpc"
    private static let blueskyActor = #"^(did:[a-z]+:[A-Za-z0-9._:%-]+|[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+)$"#

    /// Bluesky posts and profiles, from its public AppView, which names a missing post or
    /// account with a 400.
    public static let bluesky = LinkSite(name: "Bluesky", missing: [400, 404]) { url in
        let parts = url.pathParts
        guard parts.count >= 2, parts[0] == "profile", matches(blueskyActor, parts[1]) else { return nil }
        let written = parts[1]
        // Handles are case-insensitive; DIDs are not.
        let actor = written.hasPrefix("did:") ? written : written.lowercased()
        let base = "https://bsky.app/profile/\(actor)"
        guard parts.count > 2 else {
            return LinkLookup(url: base, api: "\(blueskyAPI)/app.bsky.actor.getProfile?actor=\(encodeURIComponent(actor))", preview: blueskyProfile)
        }
        guard parts[2] == "post", parts.count > 3, matches(#"^[A-Za-z0-9._:~-]{1,512}$"#, parts[3]) else { return nil }
        let rkey = parts[3]
        let uri = "at://\(actor)/app.bsky.feed.post/\(rkey)"
        return LinkLookup(url: "\(base)/post/\(rkey)",
                          api: "\(blueskyAPI)/app.bsky.feed.getPostThread?depth=0&parentHeight=0&uri=\(encodeURIComponent(uri))",
                          preview: blueskyPost,
                          fallback: actor.hasPrefix("did:") ? nil : OpenGraph(siteName: "Bluesky", title: "Post by @\(actor)"))
    }

    /// "Name (@handle)", or whichever of the two an account has.
    private static func blueskyName(_ author: JSONValue) -> String? {
        let name = clip(author["displayName"]?.stringValue)
        let handle = str(author["handle"])
        if let name, let handle { return "\(name) (@\(handle))" }
        return name ?? handle.map { "@\($0)" }
    }

    private static func blueskyPost(_ data: JSONValue) -> OpenGraph? {
        // A thread whose post is missing or blocked has no `record`.
        let post = record(record(data["thread"])["post"])
        guard let title = blueskyName(record(post["author"])), !(record(post["record"]).objectValue ?? [:]).isEmpty else { return nil }
        return OpenGraph(siteName: "Bluesky", title: title, description: clip(record(post["record"])["text"]?.stringValue))
    }

    private static func blueskyProfile(_ data: JSONValue) -> OpenGraph? {
        guard let title = blueskyName(data) else { return nil }
        return OpenGraph(siteName: "Bluesky", title: title, description: clip(data["description"]?.stringValue))
    }

    // MARK: Wikipedia

    /// Wikipedia articles in any language, from its REST API's page summary: the title and the
    /// lead's opening sentences. It follows redirects itself.
    public static let wikipedia = LinkSite(name: "Wikipedia", subdomains: true) { url in
        guard let lang = firstGroup(#"^([a-z][a-z0-9-]{1,20})\.(?:m\.)?wikipedia\.org$"#, in: url.hostname), lang != "www",
              let parts = url.decodedPathParts, parts.first == "wiki" else { return nil }
        // A title may hold a slash, written as one or as %2F.
        let title = parts.dropFirst().joined(separator: "/")
        guard !title.isEmpty, !matches(#"^special:"#, title, options: .caseInsensitive) else { return nil }
        let path = encodeURIComponent(title.replacingOccurrences(of: " ", with: "_"))
        return LinkLookup(url: "https://\(lang).wikipedia.org/wiki/\(path)", api: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(path)", preview: { data in
            guard let name = str(data["title"]) else { return nil }
            return OpenGraph(siteName: "Wikipedia", title: name, description: clip(data["extract"]?.stringValue) ?? clip(data["description"]?.stringValue))
        }, fallback: OpenGraph(siteName: "Wikipedia", title: title.replacingOccurrences(of: "_", with: " ")))
    }

    // MARK: Helpers

    /// An object, or an empty one for anything else, as apron-web's `record`.
    static func record(_ value: JSONValue?) -> JSONValue {
        if case .object = value { return value! }
        return .object([:])
    }

    /// A string with something in it.
    private static func str(_ value: JSONValue?) -> String? {
        value?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// JavaScript's truthiness for a JSON value.
    private static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool(let flag): flag
        case .string(let text): !text.isEmpty
        case .number(let text): (Double(text) ?? 0) != 0
        case .array, .object: true
        case .null, nil: false
        }
    }

    /// JavaScript's `encodeURIComponent`.
    static func encodeURIComponent(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The composer reads a draft's links on every keystroke, so each pattern compiles once.
    private static let compiled = Mutex<[String: NSRegularExpression]>([:])

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression {
        compiled.withLock { cache in
            let key = "\(options.rawValue) \(pattern)"
            if let found = cache[key] { return found }
            let made = try! NSRegularExpression(pattern: pattern, options: options)
            cache[key] = made
            return made
        }
    }

    static func matches(_ pattern: String, _ text: String, options: NSRegularExpression.Options = []) -> Bool {
        regex(pattern, options).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func firstGroup(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        regex(pattern, options).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { group(1, of: $0, in: text) }
    }

    private static func lastGroup(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        regex(pattern, options).matches(in: text, range: NSRange(text.startIndex..., in: text)).last.flatMap { group(1, of: $0, in: text) }
    }

    private static func group(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }

    static func replacing(_ pattern: String, in text: String, with template: String, options: NSRegularExpression.Options = []) -> String {
        regex(pattern, options).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Each match replaced by what `replacement` makes of its groups (the whole match first).
    private static func replacing(_ pattern: String, in text: String, options: NSRegularExpression.Options = [],
                                  _ replacement: ([String]) -> String) -> String {
        var result = "", last = text.startIndex
        for match in regex(pattern, options).matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last ..< range.lowerBound]
            result += replacement((0 ..< match.numberOfRanges).map { group($0, of: match, in: text) ?? "" })
            last = range.upperBound
        }
        return result + text[last...]
    }
}

extension URL {
    /// The host lowercased, as a browser's `URL.hostname`.
    var hostname: String { host(percentEncoded: true)?.lowercased() ?? "" }

    /// The path's segments as written (still percent-encoded), empty ones left out.
    var pathParts: [String] { path(percentEncoded: true).split(separator: "/").map(String.init) }

    /// The path's segments decoded; nil if one can't be.
    var decodedPathParts: [String]? {
        let parts = pathParts.map { $0.removingPercentEncoding }
        return parts.contains(nil) ? nil : parts.compactMap(\.self)
    }

    /// The first value of a query parameter, as `URLSearchParams.get`.
    func query(named name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}
