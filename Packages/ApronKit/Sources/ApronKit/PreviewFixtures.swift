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

    private static func message(_ minute: Int) -> String { String(start + Int64(minute) * 60_000) }

    /// Signs both servers in and opens every joined room. Returns once the stores hold it all.
    @MainActor
    public static func makeStore() async -> SessionStore {
        let tokens = InMemoryTokenStore()
        let scripts = [homeID: home, demoID: demo]
        let environment = ServerSession.Environment(
            makeTransport: { record in PreviewServer(script: scripts[record.id] ?? home) },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            jitter: { 1 },
            fetchEmojiCatalog: { _ in emojiCatalog.serializedData() }
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
            for roomID in script.histories.keys.sorted(by: codePointLess) {
                try? await session.open(roomID)
            }
            await session.loadEmojiCatalog()
        }
        return store
    }

    @MainActor
    private static func until(_ condition: () -> Bool) async {
        for _ in 0 ..< 500 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: Scripts

    private static let greeting: JSONValue = [
        "apron": 9, "auth": ["token", "guest"], "agent": "aprond/0.9",
        "capabilities": ["history", "edit", "rooms", "reactions", "status", "activity", "command", "embed:upload", "ext:emoji"],
        "ext": ["emoji": ["catalog_url": "https://home.example/emoji/catalog.json"]],
    ]

    /// Home's custom emoji: the demo's `:apron:`, an animated one with a still copy, a wide one,
    /// and a hidden one. LadleShots answers the images with generated pictures.
    private static let emojiCatalog: JSONValue = [
        ":apron:": ["url": .string(emojiURL("apron")), "width": 512, "height": 512],
        ":partyparrot:": ["url": .string(emojiURL("partyparrot")), "static_url": .string(emojiURL("partyparrot-still")),
                          "category": "Parrots", "tags": ["party", "celebrate"]],
        ":shipit:": ["url": .string(emojiURL("shipit")), "width": 64, "height": 32, "alt": "Squirrel in a hat"],
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
        "sam": ["user_id": "sam", "name": "Sam", "status": "online"],
        "ada": ["user_id": "ada", "name": "Ada Okafor", "status": "online", "roles": ["admin"]],
        "bram": ["user_id": "bram", "name": "Bram", "status": "idle"],
        "chiara": ["user_id": "chiara", "name": "Chiara", "status": "dnd", "roles": ["mod", "announce"]],
        "dev": ["user_id": "dev", "name": "Dev", "status": "offline", "roles": ["bot"]],
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

    private static func history(_ roomID: String, _ lines: [Line]) -> JSONValue {
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
            "messages": .array(messages), "reactions": .array(reactions), "more": false,
            "first_log_id": .string(message(lines.first?.minute ?? 0)), "last_log_id": .string(latest),
            "latest_log_id": .string(latest), "history_log_id": .string(message(lines.first?.minute ?? 0)),
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

    /// The room whose link cards play `og` video and audio.
    public static let linkRoomID = "design"

    private static func room(_ id: String, _ title: String, parent: String? = nil, members: [String],
                             description: String? = nil, isPrivate: Bool = false) -> JSONValue {
        var room: [String: JSONValue] = [
            "room_id": .string(id), "log_id": .string(parent == nil ? message(-600) : id), "title": .string(title),
            "members": .array(members.map { ["user_id": .string($0)] }),
        ]
        if let parent { room["parent_room_id"] = .string(parent) }
        if let description { room["description"] = .string(description) }
        if isPrivate { room["private"] = true }
        return .object(room)
    }

    /// The Release thread opens off #general after minute 8.
    private static let releaseThread = String(start + 8 * 60_000 + 45_000)
    private static let iconThread = String(start + 3 * 60_000 + 45_000)

    /// The thread whose messages link to a message, a thread and a private room's unloaded
    /// message, for the link cards; one link also comes with a sender's preview the card hides.
    public static let linkCardRoomID = iconThread
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
             // A link preview as a server that describes links would send it; aprond drops a sender's `og`.
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
                     description: "Ship Friday, then freeze"),
                room("design", "design", members: ["sam", "ada", "eunji"], description: "Icons, type and color"),
                room(iconThread, "Icon sketches", parent: "design", members: ["sam", "eunji"]),
                room("random", "random", members: ["sam", "ada", "bram", "chiara"]),
                room("ops", "ops", members: ["sam", "dev"], isPrivate: true),
                room("kitchen", "kitchen", members: ["sam", "ada", "bram", "eunji"], description: "Pots, pans and :apron:"),
            ],
            "users": .array(people.keys.sorted().map { people[$0]! }),
        ],
        histories: [
            "general": history("general", general),
            releaseThread: history(releaseThread, [
                line(10, "ada", "Checklist: version bump, origin check on both servers, passkey AASA file, release notes."),
                line(17, "bram", "AASA is live on home. Demo still serves the old app ID.", reactions: ["👀": ["ada"]]),
                line(18, "ada", "I'll fix demo tonight."),
                line(19, "dev", "Release notes draft is in the doc."),
            ]),
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
            ]),
            iconThread: history(iconThread, [
                line(-20, "eunji", "Bowl-only, 2 pt stroke, rounded caps."),
                line(-18, "sam", "Love it.", reactions: ["❤️": ["eunji"]]),
                line(-17, "eunji", "Linking the notes from #general so we don't lose them: \(notesLink)",
                     embeds: [["kind": "link", "url": .string(notesLink), "og": ["title": "general on Home", "site_name": "link.apron.chat"]]]),
                line(-16, "sam", "Checklist is in apron:?room=\(releaseThread), and the cert note in apron:?room=ops&message=\(message(-280))"),
            ]),
            "random": history("random", [
                line(-90, "chiara", "Found a 1970s Dansk enamel pot at the flea market."),
                line(-60, "bram", "Photos or it didn't happen."),
                line(-58, "chiara", "Tomorrow, the light is bad now."),
                line(-57, "chiara", "Fine, one with the flash.", embeds: [upload(1, "dansk-pot.jpg", og: ["image": media(1, "image/jpeg", 1600, 1200, alt: "A red enamel pot on a wooden table")])]),
                line(-56, "chiara", "", embeds: [upload(2, "lid-handle.mov", og: ["video": media(2, "video/quicktime", 1920, 1080)])]),
                line(-55, "bram", "The original catalogue page, for the record.", embeds: [upload(3, "Kobenstyle-catalogue-1972.pdf")]),
                line(-54, "chiara", "And it whistles.", embeds: [upload(4, "kettle.m4a", og: ["audio": media(4, "audio/mp4")])]),
                line(-53, "sam", "Mine is still uploading", embeds: [["embed_id": "embed_5", "kind": "upload", "title": "my-pot.jpg"]]),
            ]),
            "kitchen": history("kitchen", [
                line(-130, "ada", "Shipped the new glaze :apron: :partyparrot:",
                     reactions: [":partyparrot:": ["sam", "bram"], ":apron:": ["sam"], ":retired:": ["bram"], "👍": ["eunji"]]),
                line(-128, "eunji", "שלום! הסמל נראה מצוין גם מימין לשמאל :apron:", reactions: ["❤️": ["ada"]]),
                line(-127, "bram", "Keys in code stay text: `:shipit:`. Out of it, two at once :shipit::shipit:"),
                line(-126, "sam", "Lunch at 12:30:partyparrot:"),
            ]),
            "ops": history("ops", [
                line(-300, "dev", "Rotated the TLS cert on home. Next renewal in 60 days."),
                line(-290, "sam", "Thanks!"),
            ]),
        ],
        readCursors: [
            "general": message(9), releaseThread: message(17), "design": message(-30),
            iconThread: message(-18), "random": message(-90), "ops": message(-290), "kitchen": message(-126),
        ],
        notices: [[
            "room_id": "general", "from": ["user_id": "~room", "name": "general"],
            "body": ["text": "Release freeze starts Friday at 18:00 UTC. Type /help for the commands here.", "format": "plain"],
        ]]
    )

    private static let demo = PreviewServer.Script(
        greeting: cloudflareGreeting,
        you: ["user_id": "guest_7", "name": "Guest 7", "status": "online", "ext": ["permissions": ["write": false]]],
        roomList: [
            "joined": [
                room("lobby", "lobby", members: ["guest_7", "host", "wren"]),
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
        readCursors: ["lobby": message(-120), "help": message(-200)]
    )
}
