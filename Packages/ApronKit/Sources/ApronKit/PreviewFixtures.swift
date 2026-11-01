import Foundation

/// A reproducible two-server world for previews and design screenshots: rooms and threads, unread
/// rooms, replies, reactions, an edit, a deleted message, long and short messages, and presence.
/// Home is signed in with a token; the demo greets as Cloudflare's demo does (images and audio
/// only) and is signed in as a guest it lets only read.
/// Every session is a real `ServerSession` driven by a `PreviewServer`, so the views read the
/// same stores they read in the app.
public enum PreviewFixtures {
    public static let homeID = UUID(uuidString: "6C61646C-0000-4000-8000-000000000001")!
    public static let demoID = UUID(uuidString: "6C61646C-0000-4000-8000-000000000002")!
    /// The busy room and the reply the composer screenshot answers.
    public static let busyRoomID = "general"
    public static let replyTargetID = LogID(message(15))!

    /// 2026-10-27 09:00 UTC; message `n` is `n` minutes later. Message ids are server-wide, so no
    /// two rooms on one server share a minute.
    private static let start: Int64 = 1_793_091_600_000

    static func message(_ minute: Int) -> String { String(start + Int64(minute) * 60_000) }

    /// Signs both servers in and opens every joined room. Returns once the stores hold it all.
    @MainActor
    public static func makeStore() async -> SessionStore {
        let tokens = InMemoryTokenStore()
        let scripts = [homeID: home, demoID: demo]
        let environment = ServerSession.Environment(
            makeTransport: { record in PreviewServer(script: scripts[record.id] ?? home) },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            jitter: { 1 },
            fetchEmojiCatalog: { _ in emojiCatalog.serializedData() },
            fetchLinkSite: { url, _ in
                guard let answer = linkSiteAnswers[url.host() ?? ""] else { throw URLError(.notConnectedToInternet) }
                return DraftLinkPreviews.Response(status: 200, body: answer.serializedData())
            },
            typing: TypingTimes(longest: .seconds(3600)),
            readLiveText: readLiveText,
            writeLiveText: writeLiveText
        )
        let store = SessionStore(serverStore: nil, tokens: tokens, environment: environment)
        try? tokens.setToken("preview", for: homeID)
        for (id, url, label) in [(homeID, "wss://home.example/ws", "Home"), (demoID, "wss://demo.apron.example/ws", nil)] {
            store.add(ServerRecord(id: id, url: URL(string: url)!, label: label))
        }
        for (id, script) in scripts {
            guard let session = store.session(for: id) else { continue }
            if id == demoID {
                await until { session.status == .signedOut }
                _ = try? await session.signIn(.guest(name: nil))
            }
            await until { session.status == .signedIn && session.readCursors.count == script.readCursors.count }
            for roomID in script.histories.keys.sorted(by: codePointLess) where session.joinedRoomIDs.contains(roomID) {
                try? await session.open(roomID)
            }
            await session.loadEmojiCatalog()
        }
        return store
    }

    @MainActor
    static func until(_ condition: () -> Bool) async {
        for _ in 0 ..< 500 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Scripts

    private static let greeting: JSONValue = [
        "apron": 10, "auth": ["token", "guest"], "agent": "aprond/0.10",
        "capabilities": ["history", "edit", "rooms", "reactions", "status", "activity", "command", "embed:upload", "embed:terminal", "embed:append",
                         "ext", "ext:emoji", "ext:limits", "ext:settings"],
        "status": ["dnd", "invisible"],
        "ext": ["emoji": ["catalog_url": "https://home.example/emoji/catalog.json"], "settings": ["private_rooms": 5, "read_receipts": "private"]],
    ]

    /// Home's custom emoji: the demo's `:apron:`, an animated one with a still copy, a wide one,
    /// one `:smi` finds ahead of the standard emoji, and a hidden one. LadleShots answers the images with generated pictures.
    /// What GitHub's and Wikipedia's APIs answer for the links in the composer's link preview shot.
    private static let linkSiteAnswers: [String: JSONValue] = [
        "api.github.com": ["title": "Bowl-only app icon", "state": "open", "user": ["login": "eunji"],
                           "body": "Swaps the profile ladle for the bowl, with a 2 pt stroke at 20 pt.", "pull_request": ["url": "https://api.github.com/repos/example/ladle/pulls/42"]],
        "en.wikipedia.org": ["title": "Ladle (spoon)", "extract": "A ladle is a type of serving spoon used for soup, stew, or other foods."],
    ]

    /// Eun-ji's message in the link card thread whose GitHub card she built, for the sent-card shot.
    public static let sentLinkPreviewID = message(-19)

    /// A draft linking a pull request and an article, whose previews the composer builds.
    public static let linkPreviewDraft = "The icon PR is up: https://github.com/example/ladle/pull/42 and the name, for the record: https://en.wikipedia.org/wiki/Ladle_(spoon)"

    private static let emojiCatalog: JSONValue = [
        ":apron:": ["url": .string(emojiURL("apron")), "width": 512, "height": 512],
        ":partyparrot:": ["url": .string(emojiURL("partyparrot")), "static_url": .string(emojiURL("partyparrot-still")),
                          "category": "Parrots", "tags": ["party", "celebrate"]],
        ":shipit:": ["url": .string(emojiURL("shipit")), "width": 64, "height": 32, "alt": "Squirrel in a hat"],
        ":smilingpan:": ["url": .string(emojiURL("smilingpan")), "alt": "Smiling frying pan", "tags": ["kitchen"]],
        ":oldlogo:": ["url": .string(emojiURL("apron")), "hidden": true],
    ]

    public static func emojiURL(_ name: String) -> String { "https://home.example/emoji/\(name)" }

    /// The room that shows custom emoji in text, a description and reactions, and a line written
    /// right to left.
    public static let emojiRoomID = "kitchen"

    /// The `server` frame of Cloudflare's demo, server.apron.chat, without its push and welcome,
    /// with its avatar on the fixture's host.
    private static let cloudflareGreeting: JSONValue = {
        let images = ["image/png", "image/jpeg", "image/gif", "image/webp"]
        let limits = { (types: [String], bytes: Int) -> JSONValue in
            .object(Dictionary(uniqueKeysWithValues: types.map { ($0, ["max_bytes": .number(String(bytes))]) }))
        }
        return [
            "apron": 9, "auth": ["webauthn", "token", "guest"], "signup": ["webauthn", "token"], "agent": "apron-cloudflare-demo/9",
            "title": "Apron Demo", "description": "The public demo of [Apron](https://github.com/shazow/apron), an open chat protocol.",
            "avatar": .string(demoAvatarURL),
            "capabilities": ["history", "edit", "rooms", "reactions", "command", "activity", "embed:upload", "status", "ext",
                             "ext:settings", "ext:limits", "ext:media", "ext:permissions"],
            "ext": [
                "settings": ["read_cursors": true, "private_rooms": 20],
                "media": [
                    "origins": ["https://media.apron.example"],
                    "upload": limits(images + ["audio/webm", "audio/ogg", "audio/mp4"], 5_242_880),
                    "avatar": limits(images, 262_144),
                ],
            ],
        ]
    }()

    private static let people: [String: JSONValue] = [
        "sam": ["user_id": "sam", "name": "Sam", "status": "online", "ext": ["bio": "Writes Ladle. Mostly on the train."]],
        "ada": ["user_id": "ada", "name": "Ada Okafor", "status": "online", "roles": ["admin"],
                "ext": ["bio": "Runs this server. Ask me about the paging floor, or soup."]],
        "bram": ["user_id": "bram", "name": "Bram", "status": "idle"],
        "chiara": ["user_id": "chiara", "name": "Chiara", "status": "dnd", "roles": ["mod", "announce"]],
        "dev": ["user_id": "dev", "name": "Dev", "status": "offline", "seen": .string(message(-180)), "roles": ["bot"]],
        "eunji": ["user_id": "eunji", "name": "Eun-ji", "status": "online", "roles": ["announce"]],
    ]

    private struct Line {
        var minute: Int
        var from: String
        var text: String
        var reply: Int?
        var editedAt: Int?
        var deleted = false
        var reactions: [String: [String]] = [:]
        var mentions: [String] = []
        var embeds: [JSONValue] = []
        var prevRoom: String?
    }

    private static func line(_ minute: Int, _ from: String, _ text: String, reply: Int? = nil, editedAt: Int? = nil,
                             deleted: Bool = false, reactions: [String: [String]] = [:], mentions: [String] = [],
                             embeds: [JSONValue] = [], movedFrom: String? = nil) -> Line {
        Line(minute: minute, from: from, text: text, reply: reply, editedAt: editedAt, deleted: deleted, reactions: reactions,
             mentions: mentions, embeds: embeds, prevRoom: movedFrom)
    }

    /// A membership record at `second` seconds past the start, as history replays one (§4.2.2).
    private static func membership(_ roomID: String, at second: Int, _ members: [(String, Bool)]) -> JSONValue {
        [
            "log_id": .string(String(start + Int64(second) * 1000)), "room_id": .string(roomID),
            "members": .array(members.map { user, joined in ["user": people[user] ?? ["user_id": .string(user), "name": .string(user)], "joined": .bool(joined)] }),
        ]
    }

    /// `floor` is the result's `history_log_id`, the first line's by default.
    private static func history(_ roomID: String, _ lines: [Line], memberships: [JSONValue] = [], rooms: [JSONValue] = [], floor: String? = nil) -> JSONValue {
        var messages: [JSONValue] = []
        var reactions: [JSONValue] = []
        for line in lines {
            let id = message(line.minute)
            var snapshot: [String: JSONValue] = [
                "message_id": .string(id), "room_id": .string(roomID), "from": people[line.from] ?? ["user_id": .string(line.from)],
            ]
            if line.deleted {
                snapshot["log_id"] = .string(String(start + Int64(line.minute) * 60_000 + 30_000))
                snapshot["deleted"] = true
            } else {
                snapshot["log_id"] = .string(line.editedAt.map(message) ?? id)
                var body: [String: JSONValue] = ["text": .string(line.text), "format": "markdown"]
                if !line.mentions.isEmpty { body["mentions"] = .array(line.mentions.map(JSONValue.string)) }
                if !line.embeds.isEmpty { body["embeds"] = .array(line.embeds) }
                snapshot["body"] = .object(body)
            }
            if let prevRoom = line.prevRoom { snapshot["prev_room_id"] = .string(prevRoom) }
            if let reply = line.reply { snapshot["reply_to"] = ["message_id": .string(message(reply))] }
            messages.append(.object(snapshot))
            var byUser: [String: [String]] = [:]
            for (emoji, users) in line.reactions.sorted(by: { codePointLess($0.key, $1.key) }) {
                for user in users { byUser[user, default: []].append(emoji) }
            }
            for (offset, user) in byUser.keys.sorted().enumerated() {
                reactions.append([
                    "log_id": .string(String(start + Int64(line.minute) * 60_000 + 1_000 + Int64(offset))),
                    "message_id": .string(id), "room_id": .string(roomID),
                    "reactions": [["from": ["user_id": .string(user)], "emojis": .array(byUser[user]!.map(JSONValue.string))]],
                ])
            }
        }
        let latest = lines.map { $0.editedAt ?? $0.minute }.max().map(message) ?? message(0)
        return [
            "messages": .array(messages), "reactions": .array(reactions), "memberships": .array(memberships), "rooms": .array(rooms), "more": false,
            "first_log_id": .string(message(lines.first?.minute ?? 0)), "last_log_id": .string(latest),
            "latest_log_id": .string(latest), "history_log_id": .string(floor ?? message(lines.first?.minute ?? 0)),
        ]
    }

    /// A finished upload hosted on the home server (§4.8.4).
    private static func upload(_ n: Int, _ title: String, og: [String: JSONValue]? = nil) -> JSONValue {
        var embed: [String: JSONValue] = ["embed_id": .string("embed_\(n)"), "kind": "upload", "title": .string(title), "url": .string(fileURL(n))]
        if var og {
            og["title"] = .string(title)
            embed["og"] = .object(og)
        }
        return .object(embed)
    }

    private static func media(_ n: Int, _ type: String, _ width: Int? = nil, _ height: Int? = nil, alt: String? = nil) -> JSONValue {
        var media: [String: JSONValue] = ["url": .string(fileURL(n)), "type": .string(type)]
        if let width, let height { (media["width"], media["height"]) = (.number(String(width)), .number(String(height))) }
        if let alt { media["alt"] = .string(alt) }
        return .object(media)
    }

    /// The demo's server avatar; LadleShots answers it with a generated icon.
    public static let demoAvatarURL = "https://demo.apron.example/icon-512.png"

    /// Hosted files; LadleShots answers these URLs with generated media.
    public static func fileURL(_ n: Int) -> String { "https://home.example/files/embed_\(n)/s\(n)" }

    /// The room whose uploads the media screenshots show.
    public static let mediaRoomID = "random"

    /// Sam's two photos in the media room, a reply: the message the editor shot edits.
    public static var editedUploadsID: LogID { LogID(message(-59))! }

    /// The room whose link cards play `og` video and audio.
    public static let linkRoomID = "design"

    /// The room with a message of every markdown block (§3.5).
    public static let markdownRoomID = "markdown"

    /// The room whose media is on sites nobody trusts, for the media gate: the demo server's two
    /// markdown images (one on a host that resolves nowhere) and a link card whose image is the
    /// server's own but whose video is elsewhere.
    public static let elsewhereRoomID = "remote"
    public static let externalImageURL = "https://shazow.net/images/icon.png"
    public static let unreachableImageURL = "https://evildomain.example.com/image.png"

    private static let everyInline = """
    # Release 0.2 notes
    Shipping **Friday**, *after* the ~~Thursday~~ freeze. Ask @Sam, or see [the wiki](https://home.example/wiki).

    > The backoff starts over when the app returns.
    > Bram, on the reconnect bug

    ## Checklist
    1. Version bump
    2. Origin check
       - home
       - demo
    3. Release notes
    """

    private static let everyBlock = """
    ```swift
    let backoff = min(60, 1 << min(6, attempt - 1)) // seconds, before jitter and any retry_after floor
    ```

    | Server | Origin | Passkeys | Status |
    | :-- | :-- | :-: | --: |
    | home | `https://home.example` | yes | **ready** |
    | demo | `https://web.apron.chat` | no | 2 left |

    ---
    Raw <b>HTML</b> stays text.
    """

    private static let everyLanguage = """
    ```python
    @retry(times=3)
    def backoff(attempt: int) -> float:
        return min(60.0, 2 ** attempt)  # seconds
    ```

    ```diff
    --- a/Origin.swift
    +++ b/Origin.swift
    @@ -1,2 +1,2 @@
    -let origin = "https://web.apron.chat"
    +let origin = record.origin
    ```

    ```json
    {"room": "markdown", "unread": 2, "muted": false, "topic": null}
    ```

    ```brainfuck
    ++++[>++++<-]>.
    ```
    """

    private static func room(_ id: String, _ title: String?, parent: String? = nil, members: [String],
                             description: String? = nil, isPrivate: Bool = false, logID: String? = nil, latest: Int? = nil,
                             memberCount: Int? = nil) -> JSONValue {
        var room: [String: JSONValue] = [
            "room_id": .string(id), "log_id": .string(logID ?? (parent == nil ? message(-600) : id)),
            "members": .array(members.map { ["user_id": .string($0)] }),
        ]
        if let title { room["title"] = .string(title) }
        if let latest { room["latest_log_id"] = .string(message(latest)) }
        if let parent { room["parent_room_id"] = .string(parent) }
        if let description { room["description"] = .string(description) }
        if isPrivate { room["private"] = true }
        if let memberCount { room["member_count"] = .number(String(memberCount)) }
        return .object(room)
    }

    /// The Release thread opens off #general after minute 8.
    private static let releaseThread = String(start + 8 * 60_000 + 45_000)
    /// The thread renamed from "Release", whose timeline shows the rename.
    public static let releaseThreadID = releaseThread
    private static let iconThread = String(start + 3 * 60_000 + 45_000)

    /// A thread of #general started `minute` minutes from the start (45 s past it).
    private static func generalThread(_ minute: Int) -> String { String(start + Int64(minute) * 60_000 + 45_000) }

    /// #general's other joined threads, quiet for a while: the newest five of all its joined
    /// threads stay up top, and the two quiet for more than three days fold under Inactive, one
    /// of them untitled.
    private static let loadTestThread = generalThread(-150)
    private static let originThread = generalThread(-500)
    private static let docsThread = generalThread(-1200)
    private static let passkeyThread = generalThread(-5100)
    public static let untitledThreadID = generalThread(-9100)
    private static let archiveThread = generalThread(-600_100)

    /// #general's threads Sam has not joined, for Other Threads: last active 4 days, 9 weeks, 2
    /// years and 3 years before `now`, the last behind "1 more…".
    private static let otherThreads: [JSONValue] = [
        room(generalThread(-5900), "Benchmarks", parent: "general", members: ["bram"], latest: -5800),
        room(generalThread(-91000), "Hiring", parent: "general", members: ["ada"], description: "Two roles, both remote", latest: -90700),
        room(generalThread(-1_060_000), "2024 offsite", parent: "general", members: ["chiara"], latest: -1_055_000),
        room(generalThread(-1_600_000), "Icons v1", parent: "general", members: ["eunji"], latest: -1_590_000),
    ]

    /// Rooms Sam has not joined, for Browse Rooms: the garden, read before joining, and the book
    /// club, whose listing names only its most active member of 12.
    public static let gardenRoomID = "garden"
    private static let unjoinedRooms: [JSONValue] = [
        room(gardenRoomID, "garden", members: ["ada", "bram", "chiara"], description: "Seeds, soil and the allotment rota", latest: -41),
        room("books", "book-club", members: ["eunji"], description: "This month: *The Dispossessed*", latest: -700, memberCount: 12),
    ]

    /// When the rooms list's shots are taken, so "4d" and Inactive read the same every run:
    /// 2026-10-27 10:00 UTC, an hour after the first message.
    public static let now = Date(timeIntervalSince1970: Double(start) / 1000 + 3600)

    /// The thread whose messages link to a message, a thread and a private room's unloaded
    /// message, for the link cards; one link also comes with a sender's preview the card hides.
    public static let linkCardRoomID = iconThread
    /// The thread with a finished terminal's output and a finished append, then a live terminal
    /// and a live append, then a terminal and an append waiting for their writer (v10).
    public static let liveTextRoomID = loadTestThread
    private static let notesLink = "https://link.apron.chat/#server=wss://home.example/ws&room=general&message=\(message(5))"

    private static let general = [
        line(0, "ada", "morning! coffee's on ☕️"),
        line(1, "bram", "Did anyone look at the reconnect bug from yesterday? The socket still drops when the phone wakes from a long sleep, and it takes a full minute to come back.",
             reactions: ["👀": ["chiara"]]),
        line(2, "sam", "Yes. The backoff never starts over after the app returns to the foreground. Writing it up now.",
             reactions: ["🙏": ["bram"]]),
        line(3, "chiara", "Seeing it too on cellular.", reply: 1),
        line(5, "ada", "Notes from the sync: **ship 0.2 on Friday**, then freeze. The release checklist lives in the thread. Please add anything I missed, especially the passkey and origin work, since that touches the server config on both boxes.",
             reactions: ["👍": ["bram", "chiara", "sam"], "🎉": ["eunji"]]),
        line(6, "eunji", "🎉"),
        line(8, "bram", "Pushed a fix for the paging floor. Older history now stops in the right place.", editedAt: 11,
             reactions: ["❤️": ["ada", "sam"]]),
        line(9, "chiara", "nice"),
        line(12, "ada", "Confirmed on my phone. Scrolled all the way back to August.", reply: 8),
        line(13, "dev", "", deleted: true),
        line(14, "sam", "I'll cut the build after lunch.", reply: 13, reactions: ["👍": ["ada"]]),
        line(15, "eunji", "@Sam can you review the icon PR before then? It's small, mostly the ladle glyph at 20 pt.",
             // A link preview as a server that unfurls links sends it, image and all; a sender's image would be dropped.
             mentions: ["sam"], embeds: [[
                 "kind": "link", "url": "https://git.example/ladle/pull/42",
                 "og": ["title": "Ladle glyph at small sizes #42", "description": "Bowl-only mark, 2 pt stroke, rounded caps.", "site_name": "git.example",
                        "image": media(6, "image/jpeg", 1200, 630, alt: "The ladle glyph at 20 pt")],
             ]]),
        line(16, "bram", "On it. Checklist is at https://git.example/ladle/wiki/Release-0.2", reply: 15),
        line(20, "dev", "Load test plan for Friday", embeds: [["kind": "poll", "url": "https://poll.example/p/7"]],
             movedFrom: "ops"),
    ]

    private static let home = PreviewServer.Script(
        greeting: greeting,
        you: people["sam"]!,
        roomList: [
            "joined": [
                room("general", "general", members: ["sam", "ada", "bram", "chiara", "dev", "eunji"]),
                room(releaseThread, "Release 0.2", parent: "general", members: ["sam", "ada", "bram"],
                     description: "Ship Friday, then freeze", logID: String(start + 16 * 60_000 + 30_000)),
                room(loadTestThread, "Load test", parent: "general", members: ["sam", "bram"]),
                room(originThread, "Origin check", parent: "general", members: ["sam", "ada"]),
                room(docsThread, "Docs", parent: "general", members: ["sam", "eunji"], description: "What the README still owes"),
                room(passkeyThread, "Passkeys", parent: "general", members: ["sam", "ada"]),
                room(untitledThreadID, nil, parent: "general", members: ["sam", "chiara"]),
                room(archiveThread, "Archive 2025", parent: "general", members: ["sam", "dev"]),
                room("design", "design", members: ["sam", "ada", "eunji"], description: "Icons, type and color"),
                room(iconThread, "Icon sketches", parent: "design", members: ["sam", "eunji"]),
                room("random", "random", members: ["sam", "ada", "bram", "chiara"]),
                room("ops", "ops", members: ["sam", "dev"], isPrivate: true),
                room(directRoomID, nil, members: ["sam", "ada"], isPrivate: true, logID: directRoomStart),
                room(groupRoomID, nil, members: ["sam", "bram", "chiara"], isPrivate: true),
                room(addedRoomID, "Launch plan", members: ["sam", "ada", "eunji"], isPrivate: true),
                room("kitchen", "kitchen", members: ["sam", "ada", "bram", "eunji"], description: "Pots, pans and :apron:"),
                room("markdown", "markdown", members: ["sam", "ada"]),
                room("remote", "remote", members: ["sam", "bram"]),
            ],
            "users": .array(people.keys.sorted().map { people[$0]! }),
        ],
        histories: [
            // A guest who came and went nets out; Dev's join shows before the message moved in.
            "general": history("general", general, memberships: [
                membership("general", at: 19 * 60 + 10, [("guest_4", true)]),
                membership("general", at: 19 * 60 + 20, [("dev", true)]),
                membership("general", at: 19 * 60 + 30, [("guest_4", false)]),
            ]),
            // Started as "Release", renamed once the version was known.
            releaseThread: history(releaseThread, [
                line(10, "ada", "Checklist: version bump, origin check on both servers, passkey AASA file, release notes."),
                line(17, "bram", "AASA is live on home. Demo still serves the old app ID.", reactions: ["👀": ["ada"]]),
                line(18, "ada", "I'll fix demo tonight."),
                line(19, "dev", "Release notes draft is in the doc."),
            ], rooms: [
                ["room_id": .string(releaseThread), "log_id": .string(releaseThread), "parent_room_id": "general", "title": "Release",
                 "description": "Ship Friday, then freeze"],
            ]),
            // A v10 server's live text once it ended: a terminal's kept output, an append in the body.
            loadTestThread: history(loadTestThread, [
                line(-142, "bram", "Smoke run before the ramp:", embeds: [[
                    "embed_id": "embed_t1", "kind": "terminal", "title": "make smoke",
                    "output": "\u{1B}[1mrunning 4 checks\u{1B}[0m\r\nconnect   \u{1B}[32mok\u{1B}[0m  12 ms\r\nauth      \u{1B}[32mok\u{1B}[0m  31 ms\r\nhistory   \u{1B}[32mok\u{1B}[0m  48 ms\r\nfan-out   \u{1B}[33mslow\u{1B}[0m 412 ms\r\nprogress 100%\r\n",
                ]]),
                line(-141, "bram", "Plan for the ramp:\n\n1. 100 connections, hold five minutes.\n2. 500 at noon.\n3. Roll back if fan-out passes a second."),
                line(-140, "bram", "Ramping to 500 connections at noon."),
                line(-139, "dev", "Watching the ramp live:", embeds: [[
                    "embed_id": "embed_t2", "kind": "terminal", "title": "make ramp", "url": .string(liveTerminalURL.absoluteString),
                ]]),
                line(-138, "ada", "Asked the planner what to do if it fails:\n\n", embeds: [[
                    "embed_id": "embed_a2", "kind": "append", "url": .string(liveAppendURL.absoluteString),
                ]]),
                // Live text whose writer has not started: no url yet (§4.8.5).
                line(-137, "dev", "Next, the soak test:", embeds: [[
                    "embed_id": "embed_t3", "kind": "terminal", "title": "make soak",
                ]]),
                line(-136, "bram", "Drafting the ramp report:\n\n", embeds: [[
                    "embed_id": "embed_a3", "kind": "append",
                ]]),
            ]),
            originThread: history(originThread, [line(-480, "ada", "Both boxes send the right Origin now.")]),
            docsThread: history(docsThread, [line(-1100, "eunji", "The sign-in section needs a QR screenshot.")]),
            passkeyThread: history(passkeyThread, [line(-5000, "sam", "AASA plan: one file per domain.")]),
            untitledThreadID: history(untitledThreadID, [line(-9000, "chiara", "Notes from the offsite, before I lose them.")]),
            archiveThread: history(archiveThread, [line(-600_000, "dev", "Last year's release checklists, for reference.")]),
            "design": history("design", [
                line(-40, "eunji", "Three takes on the app icon: a ladle in profile, a ladle from above, and just the bowl."),
                line(-38, "ada", "From above reads best at small sizes."),
                line(-30, "sam", "Agree. The profile one turns into a spoon below 40 pt."),
                line(-25, "sam", "The 20 pt walkthrough, if you want to see the glyph move.",
                     embeds: [["kind": "link", "url": "https://home.example/clips/glyph", "og": [
                         "title": "Ladle glyph at 20 pt", "description": "A thirty second pass over the bowl-only mark.", "site_name": "home.example",
                         "image": media(7, "image/jpeg", 1200, 630), "video": media(8, "video/mp4", 1200, 630)]]]),
                line(-24, "sam", "And the kettle, for the icon's sound.",
                     embeds: [["kind": "link", "url": "https://home.example/clips/kettle", "og": [
                         "title": "Kettle, close up", "description": "The whistle the glyph is named for.", "site_name": "home.example",
                         "image": media(9, "image/jpeg", 1200, 630), "audio": media(10, "audio/mp4")]]]),
                // A role mention: Eun-ji holds announce, so she is listed; Sam, who reads it, is not.
                line(-22, "ada", "@&announce the bowl-only mark is in the Icon sketches thread. Not `@&announce` in code.",
                     mentions: ["eunji"]),
            ]),
            iconThread: history(iconThread, [
                line(-20, "eunji", "Bowl-only, 2 pt stroke, rounded caps."),
                // A link preview as Ladle and apron-web build it for GitHub; the server keeps its text.
                line(-19, "eunji", "Up for review: https://github.com/example/ladle/pull/42",
                     embeds: [["kind": "link", "url": "https://github.com/example/ladle/pull/42", "og": [
                         "site_name": "GitHub · example/ladle", "title": "Bowl-only app icon",
                         "description": "Pull request #42 · Open · by eunji — Swaps the profile ladle for the bowl, with a 2 pt stroke at 20 pt."]]]),
                line(-18, "sam", "Love it.", reactions: ["❤️": ["eunji"]]),
                line(-17, "eunji", "Linking the notes from #general so we don't lose them: \(notesLink)",
                     embeds: [["kind": "link", "url": .string(notesLink), "og": ["title": "general on Home", "site_name": "link.apron.chat"]]]),
                line(-16, "sam", "Checklist is in apron:?room=\(releaseThread), and the cert note in apron:?room=ops&message=\(message(-280))"),
                // Apron links as chips: a message, a room, a thread, a user, and a room on another server.
                line(-15, "sam", "Round-up: apron:?room=general&message=\(message(5)), apron:?room=design, apron:?room=\(releaseThread), apron:?room=\(iconThread)&user=ada, and the demo's https://link.apron.chat/#server=wss://demo.apron.example/ws&room=lobby"),
            ]),
            "random": history("random", [
                line(-90, "chiara", "Found a 1970s Dansk enamel pot at the flea market."),
                line(-60, "bram", "Photos or it didn't happen."),
                line(-59, "sam", "Mine first: lid and base.", reply: -60, embeds: [
                    upload(10, "IMG_4021.jpg", og: ["image": media(10, "image/jpeg", 1200, 1600)]),
                    upload(11, "IMG_4022.jpg", og: ["image": media(11, "image/jpeg", 1600, 1200)]),
                ]),
                line(-58, "chiara", "Tomorrow, the light is bad now."),
                line(-57, "chiara", "Fine, one with the flash.", embeds: [upload(1, "dansk-pot.jpg", og: ["image": media(1, "image/jpeg", 1600, 1200, alt: "A red enamel pot on a wooden table")])]),
                line(-56, "chiara", "", embeds: [upload(2, "lid-handle.mov", og: ["video": media(2, "video/quicktime", 1920, 1080)])]),
                line(-55, "bram", "The original catalogue page, for the record.", embeds: [upload(3, "Kobenstyle-catalogue-1972.pdf")]),
                line(-54, "chiara", "And it whistles.", embeds: [upload(4, "kettle.m4a", og: ["audio": media(4, "audio/mp4")])]),
                line(-53, "sam", "Mine is still uploading", embeds: [["embed_id": "embed_5", "kind": "upload", "title": "my-pot.jpg"]]),
            ]),
            gardenRoomID: history(gardenRoomID, [
                line(-44, "chiara", "The tomatoes made it through the frost."),
                line(-43, "bram", "Who has the rota this week?"),
                line(-41, "ada", "Me. Watering Tuesday and Friday."),
            ]),
            "kitchen": history("kitchen", [
                line(-130, "ada", "Shipped the new glaze :apron: :partyparrot:",
                     reactions: [":partyparrot:": ["sam", "bram"], ":apron:": ["sam"], ":retired:": ["bram"], "👍": ["eunji"]]),
                line(-128, "eunji", "שלום! הסמל נראה מצוין גם מימין לשמאל :apron:", reactions: ["❤️": ["ada"]]),
                line(-127, "bram", "Keys in code stay text: `:shipit:`. Out of it, two at once :shipit::shipit:"),
                line(-126, "sam", "Lunch at 12:30:partyparrot:"),
            ]),
            "markdown": history("markdown", [
                line(-401, "ada", everyInline, mentions: ["sam"]),
                line(-400, "ada", everyBlock),
                line(-399, "bram", everyLanguage),
            ]),
            "remote": history("remote", [
                line(-410, "bram", "The walkthrough, hosted elsewhere.",
                     embeds: [["kind": "link", "url": "https://video.example/glyph", "og": [
                         "title": "Ladle glyph at 20 pt", "site_name": "video.example",
                         "image": media(7, "image/jpeg", 1200, 630), "video": ["url": "https://video.example/glyph.mp4", "type": "video/mp4", "width": 1280, "height": 720]]]]),
                line(-409, "bram", "![embedded image from an external host](\(externalImageURL))"),
                line(-408, "bram", "![](\(unreachableImageURL))"),
            ]),
            "ops": history("ops", [
                line(-300, "dev", "Rotated the TLS cert on home. Next renewal in 60 days."),
                line(-290, "sam", "Thanks!"),
            ]),
            // From its creation: the intro card heads it.
            directRoomID: history(directRoomID, [
                line(30, "ada", "Got a minute for the cert renewal before Friday?"),
                line(31, "sam", "Sure, after lunch."),
                line(32, "ada", "Great. I'll bring the checklist."),
            ], floor: directRoomStart),
            groupRoomID: history(groupRoomID, [
                line(33, "bram", "Flea market on Saturday?"),
                line(34, "chiara", "Only if we're back by noon."),
            ]),
            addedRoomID: history(addedRoomID, [line(35, "eunji", "Added you so you can see the press list.")]),
        ],
        readCursors: [
            "general": message(9), releaseThread: message(17), "design": message(-22),
            iconThread: message(-18), "random": message(-90),
            loadTestThread: message(-136), originThread: message(-480), docsThread: message(-1100), passkeyThread: message(-5000),
            untitledThreadID: message(-9000), archiveThread: message(-600_000), "ops": message(-290), "kitchen": message(-126),
            "markdown": message(-399), "remote": message(-408),
            directRoomID: message(31), groupRoomID: message(34), addedRoomID: message(35),
        ],
        notices: [[
            "room_id": "general", "from": ["user_id": "~room", "name": "general"],
            "body": ["text": "Release freeze starts Friday at 18:00 UTC. Type /help for the commands here.", "format": "plain"],
        ], [
            "room_id": "ops", "from": ["user_id": "~private", "name": "System message to you"],
            "body": ["text": .string(inviteDeviceNotice), "format": "markdown"],
        ]],
        activities: [
            ["room_id": .string(typingRoomID), "from": people["ada"]!, "typing": 3600],
            ["room_id": .string(typingRoomID), "from": people["bram"]!, "typing": 3600],
            // Read receipts: Ada read through Sam's reply; Bram and Chiara read the crew's last message.
            ["room_id": .string(directRoomID), "from": ["user_id": "ada"], "read_message_id": .string(message(31))],
            ["room_id": .string(groupRoomID), "from": ["user_id": "bram"], "read_message_id": .string(message(34))],
            ["room_id": .string(groupRoomID), "from": ["user_id": "chiara"], "read_message_id": .string(message(34))],
        ],
        statuses: [["room_id": .string(mutedRoomID), "mute": true]],
        unjoinedThreads: ["general": .array(otherThreads)],
        unjoinedRooms: unjoinedRooms
    )

    /// The conversation with Ada: private, untitled, so named for her, its history from its start.
    /// apron-server-rust's `/invite-device add phone` notice, word for word, with a made-up token.
    public static let inviteDeviceNotice = """
        This token signs in as you (`sam`) on your device **phone**. It does not expire, and anyone who has it can sign in as you, so keep it secret. `/invite-device add phone` again replaces it, and `/invite-device remove phone` revokes it.

        ```
        \(previewDeviceToken)
        ```

        Or open this link on **phone**, which signs you in there with any Apron app: <\(inviteDeviceLink)>

        To sign in, authenticate with the token scheme: `{"method": "auth", "params": {"scheme": "token", "token": "\(previewDeviceToken)"}}`
        """
    public static let inviteDeviceLink = "https://link.apron.chat/#server=wss://home.example/ws&token=\(previewDeviceToken)"
    private static let previewDeviceToken = "apron_device_PREVIEW-not-a-real-token"

    public static let directRoomID = "dm_ada"
    private static let directRoomStart = String(start + 30 * 60_000 - 30_000)
    /// A private room with Bram and Chiara, named "Bram, Chiara".
    public static let groupRoomID = "dm_crew"
    /// A private room Ada added you to, with its banner.
    public static let addedRoomID = "launch"

    /// The room muted until unmuted, with its threads: its rows ring no bell.
    public static let mutedRoomID = "design"

    /// The room where Ada and Bram are typing, held for an hour so every shot of it sees them.
    public static let typingRoomID = "random"

    /// The demo's lobby lists only its three most recently active members of this many (§4.2.1).
    public static let lobbyMemberCount = 1204

    private static let demo = PreviewServer.Script(
        greeting: cloudflareGreeting,
        you: ["user_id": "guest_7", "name": "Guest 7", "status": "online", "ext": ["permissions": ["write": false]]],
        roomList: [
            "joined": [
                room("lobby", "lobby", members: ["guest_7", "host", "wren"], memberCount: lobbyMemberCount),
                room("help", "help", members: ["guest_7", "host"]),
            ],
            "users": [
                ["user_id": "guest_7", "name": "Guest 7", "status": "online"],
                ["user_id": "host", "name": "Demo Host", "status": "online"],
                ["user_id": "wren", "name": "Wren", "status": "idle"],
            ],
        ],
        histories: [
            "lobby": history("lobby", [
                line(-120, "host", "Welcome to the Apron demo server. Be kind; history resets nightly."),
                line(-15, "wren", "Anyone tried the Rust server with email sign-in?"),
                line(-14, "host", "Yes, `--email.enable` and a sender. Works fine."),
                line(-5, "wren", "Thanks!"),
            ]),
            "help": history("help", [
                line(-200, "host", "Ask here. Logs help: include your client and server versions."),
            ]),
        ],
        readCursors: ["lobby": message(-120), "help": message(-200)],
        welcome: ["from": ["user_id": "~private", "name": "Only you"], "body": ["text": .string(demoWelcome), "format": "markdown"]],
        token: nil
    )

    /// The demo's welcome before `auth`, which shows in its first room, help, for a guest it gives
    /// no token.
    public static let demoWelcome = "Welcome to the Apron demo. Guests can read. **Sign in with a passkey** to post."
}
