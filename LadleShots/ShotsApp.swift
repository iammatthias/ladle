import ApronKit
import SwiftUI
import UIKit

/// The design-review renderer. With `LADLE_SHOTS_DIR` set, it seeds `PreviewFixtures`, renders
/// the first run (no servers) and each screen the web-parity pairs compare at iPhone size
/// (390x844) in dark and light, the timeline at AX3, and the iPad split view (1180x820) in dark
/// and light, writes a PNG per shot and `contrast.json`, and quits. AGENTS.md, "Design review", has the commands.
@main
struct ShotsApp: App {
    @State private var shot = AnyView(Color.clear)

    var body: some Scene {
        WindowGroup {
            shot.task { await Renderer.run { shot = $0 } }
        }
    }
}

enum Screen: String, CaseIterable {
    case firstRun = "first-run", servers, connect, connectScanned = "connect-scanned", rooms, timeline, mention, members, reaction, attachments, media, links, viewer, ipad
    case textLimit = "text-limit", guestComposer = "guest-composer"
    case emoji, emojiPicker = "emoji-picker", emojiShortcode = "emoji-shortcode", commands
    case linkCards = "link-cards", roomMention = "room-mention", selectText = "select-text"
    case reminder, reminderCustom = "reminder-custom"
    case markdown, mediaGate = "media-gate", mediaGateLoaded = "media-gate-loaded"
    case you, profileCard = "profile-card", profileCardOffline = "profile-card-offline", serverPane = "server-pane", serverPaneDemo = "server-pane-demo", mentionChip = "mention-chip"
    case draftKept = "draft-kept", typing, ipadTyping = "ipad-typing", rolePicker = "role-picker", roleChip = "role-chip"
    case muted, paused, notificationsPaused = "notifications-paused", limited
    case appearance, appearanceCustom = "appearance-custom", preferences, history
    case threadRenamed = "thread-renamed", startThread = "start-thread"

    /// Shots of home with its notifications paused.
    var isPaused: Bool { self == .paused || self == .notificationsPaused }

    var isPad: Bool { self == .ipad || self == .ipadTyping }
}

@MainActor
enum Renderer {
    static let phone = CGSize(width: 390, height: 844)
    static let pad = CGSize(width: 1180, height: 820)

    static func run(show: (AnyView) -> Void) async {
        guard let path = ProcessInfo.processInfo.environment["LADLE_SHOTS_DIR"],
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scene.titlebar?.titleVisibility = .hidden
        scene.titlebar?.toolbar = nil
        Appearance.apply()
        let media = URLSessionConfiguration.default
        media.protocolClasses = [FixtureMedia.self] + (media.protocolClasses ?? [])
        MediaLoader.shared = MediaLoader(configuration: media)
        LinkPreviews.shared = LinkPreviews(directory: nil) { url in
            url.host() == "git.example" ? FixtureMedia.wikiPreview : nil
        }
        let staged = FixtureMedia.stagedAttachments()
        UserDefaults.standard.set(true, forKey: "otherThreadsOpen")

        let store = await PreviewFixtures.makeStore()
        guard let home = store.session(for: PreviewFixtures.homeID) else { exit(1) }

        var shots: [(screen: Screen, style: UIUserInterfaceStyle, large: Bool, look: Look?)] = []
        for screen in Screen.allCases where screen != .limited {
            shots.append((screen, .dark, false, Look.seeded(screen)))
            shots.append((screen, .light, false, Look.seeded(screen)))
        }
        shots.append((.timeline, .dark, true, nil))
        // The busy room in each premade theme but Apron, which every other shot is in, and in the
        // custom CSS of the custom Appearance shot.
        for look in PremadeTheme.all.dropFirst().map(Look.premade) + [Look.custom] {
            shots.append((.timeline, .dark, false, look))
            shots.append((.timeline, .light, false, look))
        }
        // The busy room drawn in Apron and then given Linocut without being made again: what a
        // theme chosen in Preferences does to the screens already open.
        shots.append((.timeline, .dark, false, Look.switched))
        // Last, since the waits it asks for hold home back for the shots after it.
        shots.append((.limited, .dark, false, nil))
        shots.append((.limited, .light, false, nil))

        let only = ProcessInfo.processInfo.environment["LADLE_SHOTS_ONLY"]
        for shot in shots {
            let theme = shot.look?.label.map { "-\($0)" } ?? ""
            let name = "ladle-\(shot.screen.rawValue)\(theme)-\(shot.large ? "ax3" : shot.style == .dark ? "dark" : "light").png"
            if let only, !name.contains(only) { continue }
            let size = shot.screen.isPad ? pad : phone
            scene.sizeRestrictions?.minimumSize = .zero
            scene.sizeRestrictions?.maximumSize = size
            scene.sizeRestrictions?.minimumSize = size
            scene.windows.first?.overrideUserInterfaceStyle = shot.style
            store.appearance.update(shot.look?.preferences ?? .default)
            ActiveTheme.shared.theme = shot.look?.drawnIn ?? store.appearance.shown
            await seedReminder(shot.screen == .reminder, in: store, home: home)
            await seedPause(shot.screen.isPaused, home: home)
            if shot.screen == .limited { await seedWaits(home: home) }
            show(AnyView(view(shot.screen, store: store, home: home, staged: staged)
                .environment(\.fixedTypeSize, shot.large ? .accessibility3 : .large)
                .environment(\.scenePhase, .inactive)
                .environment(\.liveSessions, SessionLookup(store.liveSession(for:)))
                .environment(\.fixedNow, PreviewFixtures.now)
                .dynamicTypeSize(shot.large ? .accessibility3 : .large)
                .apronStyle()
                .id(UUID())))
            try? await Task.sleep(for: .milliseconds(shot.screen.isPad ? 2500 : 1500))
            if shot.look?.drawnIn != nil {
                ActiveTheme.shared.theme = store.appearance.shown
                try? await Task.sleep(for: .milliseconds(1000))
            }
            capture(scene, to: directory.appending(path: name))
        }
        writeContrast(to: directory.appending(path: "contrast.json"))
        exit(0)
    }

    static func view(_ screen: Screen, store: SessionStore, home: ServerSession, staged: [StagedFile]) -> AnyView {
        switch screen {
        case .appearance:
            AnyView(NavigationStack { AppearanceView(editor: ThemeEditor(settings: store.appearance)) })
        case .appearanceCustom:
            AnyView(NavigationStack { ThemeCSSView(editor: ThemeEditor(settings: store.appearance)) })
        case .firstRun:
            AnyView(NavigationStack {
                ServerListView(store: SessionStore(serverStore: nil, tokens: InMemoryTokenStore()), open: { _ in }, connecting: .constant(nil))
            })
        case .servers:
            AnyView(NavigationStack { ServerListView(store: store, open: { _ in }, connecting: .constant(nil)) })
        case .connect:
            AnyView(ConnectView(store: store, canScan: true))
        case .connectScanned:
            AnyView(ConnectView(store: store, prefill: TokenPayload(token: "inv_Qm7x", server: URL(string: "wss://chat.example/ws")),
                                canScan: true))
        case .rooms:
            AnyView(NavigationStack { RoomListView(session: home, selected: PreviewFixtures.busyRoomID, open: { _ in }) })
        case .timeline:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.busyRoomID, reminders: store.reminders, drafts: Drafts()) })
        case .mention:
            AnyView(NavigationStack {
                TimelineView(session: home, roomID: PreviewFixtures.busyRoomID, reminders: store.reminders, drafts: kept(home, PreviewFixtures.busyRoomID, ComposerDraft(field: DraftField(text: "Thanks @"))))
            })
        case .members:
            AnyView(NavigationStack { MemberList(session: home, roomID: PreviewFixtures.busyRoomID) })
        case .reaction:
            AnyView(ReactionPicker { _ in })
        case .attachments:
            AnyView(NavigationStack {
                TimelineView(session: home, roomID: PreviewFixtures.mediaRoomID, reminders: store.reminders, drafts: kept(home, PreviewFixtures.mediaRoomID, ComposerDraft(field: DraftField(text: "Both sides of mine"), files: staged)))
            })
        case .media:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.mediaRoomID, reminders: store.reminders, drafts: Drafts()) })
        case .links:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.linkRoomID, reminders: store.reminders, drafts: Drafts()) })
        case .viewer:
            AnyView(MediaViewer(items: home.mediaItems(in: PreviewFixtures.mediaRoomID),
                                selection: home.mediaItems(in: PreviewFixtures.mediaRoomID).first?.id ?? ""))
        case .textLimit:
            AnyView(NavigationStack {
                TimelineView(session: home, roomID: PreviewFixtures.busyRoomID, reminders: store.reminders,
                             drafts: kept(home, PreviewFixtures.busyRoomID, ComposerDraft(field: DraftField(text: String(repeating: "Release notes for 0.2, every change since August. ", count: 82) + "🎉"))))
            })
        case .guestComposer:
            AnyView(NavigationStack {
                if let demo = store.session(for: PreviewFixtures.demoID) { TimelineView(session: demo, roomID: "lobby", reminders: store.reminders, drafts: Drafts()) }
            })
        case .emoji:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.emojiRoomID, reminders: store.reminders, drafts: Drafts()) })
        case .emojiPicker:
            AnyView(ReactionPicker(session: home) { _ in })
        case .emojiShortcode:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.emojiRoomID, reminders: store.reminders, drafts: kept(home, PreviewFixtures.emojiRoomID, ComposerDraft(field: DraftField(text: "Lunch :pa")))) })
        case .commands:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.busyRoomID, reminders: store.reminders, drafts: kept(home, PreviewFixtures.busyRoomID, ComposerDraft(field: DraftField(text: "/inv")))) })
        case .linkCards:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.linkCardRoomID, reminders: store.reminders, drafts: Drafts()) })
        case .roomMention:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.linkCardRoomID, reminders: store.reminders, drafts: kept(home, PreviewFixtures.linkCardRoomID, ComposerDraft(field: DraftField(text: "Moving this to #s")))) })
        case .selectText:
            AnyView(SelectTextSheet(text: home.timeline(PreviewFixtures.busyRoomID).first { $0.plainText.hasPrefix("Notes from the sync") }
                .map { MessageText.plain($0.body) } ?? "") {})
        case .reminder:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.busyRoomID, reminders: store.reminders, drafts: Drafts()) })
        case .reminderCustom:
            AnyView(ReminderDateSheet(date: .constant(Date(timeIntervalSince1970: 1_793_440_800)), set: {}, cancel: {}))
        case .markdown:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.markdownRoomID, reminders: store.reminders, drafts: Drafts()) })
        case .mediaGate:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.elsewhereRoomID, reminders: store.reminders, drafts: Drafts()) })
        case .mediaGateLoaded:
            // Load, tapped on both images and the video.
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.elsewhereRoomID, reminders: store.reminders, drafts: Drafts()) }
                .onAppear {
                    for url in [PreviewFixtures.externalImageURL, PreviewFixtures.unreachableImageURL, "https://video.example/glyph.mp4"] {
                        home.mediaSettings.loadOnce(URL(string: url)!)
                    }
                })
        case .you:
            AnyView(YouView(session: home))
        case .profileCard:
            AnyView(ProfileCardView(session: home, request: ProfileRequest(user: UserObject(["user_id": "ada"])!, roomID: "ops")))
        case .profileCardOffline:
            AnyView(ProfileCardView(session: home, request: ProfileRequest(user: UserObject(["user_id": "dev"])!, roomID: PreviewFixtures.busyRoomID)))
        case .mentionChip:
            // Eun-ji's "@Sam", revealed and highlighted as a link to it opens it.
            AnyView(NavigationStack {
                TimelineView(session: home, roomID: PreviewFixtures.busyRoomID, reminders: store.reminders, drafts: Drafts(),
                             place: .constant(ApronLink(room: PreviewFixtures.busyRoomID, message: LogID("1793092500000"))))
            })
        case .serverPane:
            AnyView(ServerPaneView(session: home))
        case .serverPaneDemo:
            AnyView(Group { if let demo = store.session(for: PreviewFixtures.demoID) { ServerPaneView(session: demo) } })
        case .draftKept:
            // The busy room's kept draft as a relaunch brings it back: a reply to Eun-ji, text and a photo.
            AnyView(NavigationStack {
                TimelineView(session: home, roomID: PreviewFixtures.busyRoomID, reminders: store.reminders,
                             drafts: kept(home, PreviewFixtures.busyRoomID, ComposerDraft(
                                 field: DraftField(mode: .reply(LogID("1793092500000")!), text: "On it. Here's the 20 pt one at 3x"),
                                 files: Array(staged.prefix(1)))))
            })
        case .threadRenamed:
            // The Release thread's rename, and in #general (the busy room) Dev's join.
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.releaseThreadID, reminders: store.reminders, drafts: Drafts()) })
        case .startThread:
            // Start Thread on Bram's checklist message: its first line as the title, its text quoted.
            AnyView(Group {
                if let message = home.timeline(PreviewFixtures.busyRoomID).first(where: { $0.plainText.hasPrefix("Did anyone look") }) {
                    RoomFormSheet(kind: .thread, mode: .create, subtitle: "In general", title: ThreadStart.title(message.body),
                                  description: ThreadStart.description(message.body) ?? "") { _, _ in }
                }
            })
        case .typing:
            // Ada and Bram typing: the header's subtitle on a phone.
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.typingRoomID, reminders: store.reminders, drafts: Drafts()) })
        case .rolePicker:
            // `@&` lists the roles others here hold, with how many each mentions.
            AnyView(NavigationStack {
                TimelineView(session: home, roomID: PreviewFixtures.busyRoomID, reminders: store.reminders,
                             drafts: kept(home, PreviewFixtures.busyRoomID, ComposerDraft(field: DraftField(text: "Release is out, @&"))))
            })
        case .limited:
            // Sending paused by a posting limit (the ring and Send counting down), and uploads
            // paused for two hours (the clock, which can be put away).
            AnyView(NavigationStack {
                TimelineView(session: home, roomID: PreviewFixtures.busyRoomID, reminders: store.reminders,
                             drafts: kept(home, PreviewFixtures.busyRoomID, ComposerDraft(field: DraftField(text: "Right after this"))))
            })
        case .muted:
            // A muted room: the bell-off left of ⋯ in its header, and its thread card.
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.mutedRoomID, reminders: store.reminders, drafts: Drafts()) })
        case .paused:
            // The profile bar while paused, over the muted room and its thread's bells.
            AnyView(NavigationStack { RoomListView(session: home, selected: PreviewFixtures.busyRoomID, open: { _ in }) })
        case .notificationsPaused:
            AnyView(PreferencesView(store: store, request: PreferencesRequest(section: .notifications, server: PreviewFixtures.homeID)))
        case .preferences:
            AnyView(PreferencesView(store: store))
        case .history:
            AnyView(PreferencesView(store: store, request: PreferencesRequest(section: .history)))
        case .roleChip:
            // Ada's `@&announce` as a role chip, and the same words in code left as written.
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.linkRoomID, reminders: store.reminders, drafts: Drafts()) })
        case .ipad:
            AnyView(SplitLayout(store: store, serverID: .constant(PreviewFixtures.homeID.uuidString),
                                roomID: .constant(PreviewFixtures.busyRoomID), place: .constant(nil), connecting: .constant(nil)))
        case .ipadTyping:
            // The same, wider: the line with the dots above the composer.
            AnyView(SplitLayout(store: store, serverID: .constant(PreviewFixtures.homeID.uuidString),
                                roomID: .constant(PreviewFixtures.typingRoomID), place: .constant(nil), connecting: .constant(nil)))
        }
    }

    /// Drafts holding one room's draft, for a shot of its composer.
    static func kept(_ session: ServerSession, _ roomID: String, _ draft: ComposerDraft) -> Drafts {
        Drafts([DraftKey(server: session.record.id, roomID: roomID): draft])
    }

    /// A reminder an hour off on the busy room's last message from Bram, for its shot alone.
    /// Asks home's preview server for a refused reaction and a refused upload, once.
    static func seedWaits(home: ServerSession) async {
        guard home.sendWait == nil, let message = home.timeline(PreviewFixtures.busyRoomID).last else { return }
        // The upload first: once posting waits, the message with it would not go.
        let photo = Attachment(fileURL: URL(filePath: "/tmp/limited.png"), title: "limited.png", contentType: "image/png", byteCount: 10)
        try? await home.send("", in: PreviewFixtures.busyRoomID, attachments: [photo])
        try? await home.toggleReaction(PreviewServer.slowReaction, on: message.messageID)
    }

    /// Pauses home until resumed for the paused shots (the preview server echoes it), else resumes.
    static func seedPause(_ paused: Bool, home: ServerSession) async {
        guard (home.pause != nil) != paused else { return }
        try? await home.setPause(paused ? .untilChanged : nil)
        for _ in 0 ..< 100 where (home.pause != nil) != paused { try? await Task.sleep(for: .milliseconds(10)) }
    }

    static func seedReminder(_ shown: Bool, in store: SessionStore, home: ServerSession) async {
        guard let message = home.timeline(PreviewFixtures.busyRoomID).last(where: { $0.from.userID == "bram" }) else { return }
        let reminder = home.reminder(for: message, due: .now.addingTimeInterval(3630))
        if shown { await store.reminders.set(reminder) } else { await store.reminders.remove(reminder.key) }
    }

    static func capture(_ scene: UIWindowScene, to url: URL) {
        guard let window = scene.windows.first else { return }
        window.makeKey()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: url)
    }

    /// A theme a shot is taken in, other than the saved Apron, and what its file name says.
    struct Look {
        var label: String?
        var preferences: AppearancePreferences
        /// Drawn in this first, then given `preferences`' theme without being made again.
        var drawnIn: ResolvedTheme?

        static func premade(_ theme: PremadeTheme) -> Look { Look(label: theme.id, preferences: AppearancePreferences(theme: theme.id)) }

        static let custom = Look(label: "custom", preferences: AppearancePreferences(theme: AppearancePreferences.custom, customCSS: customCSS))
        static let switched = Look(label: "switched-linocut", preferences: AppearancePreferences(theme: "linocut"), drawnIn: .apron)

        /// The Appearance shots: Ferrous chosen, and Custom with its CSS open.
        static func seeded(_ screen: Screen) -> Look? {
            switch screen {
            case .appearance: Look(preferences: AppearancePreferences(theme: "ferrous"))
            case .appearanceCustom: Look(preferences: custom.preferences)
            default: nil
            }
        }

        /// A custom theme as someone might paste it from apron-web: base colors, a face, a radius,
        /// and two tokens iOS has no use for.
        static let customCSS = """
        :root {
        \t/* Interface */
        \t--font-sans: ui-rounded, var(--font-sans-system);
        \t/* Messages */
        \t--font-chat: var(--font-sans);
        \t/* Code, embeds and commands */
        \t--font-mono: var(--font-mono-system);
        \t/* Sea glass */
        \t--base-ground: light-dark(#eef6f3, #10201c);
        \t--base-ink: light-dark(#14302a, #dcefe9);
        \t--base-accent: light-dark(#0f6b5c, #5fd3bd);
        \t--base-link: light-dark(#235a9c, #8cbcf0);
        \t--radius-md: 14px;
        \t--z-menu: 9;
        \t--font-emoji: "Noto Color Emoji";
        }

        """
    }

    /// WCAG 2 contrast of the text tokens on the grounds they sit on, per mode, for each premade
    /// theme by id.
    static func writeContrast(to url: URL) {
        let pairs: [(String, String, String)] = [
            ("ink on timeline", "--ink", "--bg-100"), ("ink-muted on timeline", "--ink-muted", "--bg-100"),
            ("ink-muted on chrome", "--ink-muted", "--bg-000"), ("ink on raised", "--ink", "--bg-200"),
            ("ink-muted on rail", "--ink-muted", "--bg-rail"),
            ("on-accent on accent", "--on-accent", "--accent"), ("accent on timeline", "--accent", "--bg-100"),
            ("denim on denim-soft", "--denim", "--denim-soft"), ("denim on timeline", "--denim", "--bg-100"),
            ("ink on accent-soft", "--ink", "--accent-soft"), ("private on private-soft", "--private", "--private-soft"),
            ("danger on timeline", "--danger", "--bg-100"), ("line-strong on timeline", "--line-strong", "--bg-100"),
        ]
        func ratio(_ a: RGBA, _ b: RGBA) -> JSONValue { .number(String(format: "%.2f", a.contrast(with: b))) }
        var report: [String: JSONValue] = [:]
        for premade in PremadeTheme.all {
            guard let theme = PremadeTheme.resolved[premade.id] else { continue }
            report[premade.id] = .array(pairs.map { name, text, ground in
                let (t, g) = (theme.color(text), theme.color(ground))
                return ["pair": .string(name), "dark": ratio(t.dark, g.dark), "light": ratio(t.light, g.light)]
            })
        }
        try? JSONValue.object(report).serializedData().write(to: url)
    }
}

/// Answers the fixtures' hosted files (`PreviewFixtures.fileURL`) with generated media, and
/// stages the composer's attachments, so the media screens render without a network.
final class FixtureMedia: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        ["home.example", "demo.apron.example", "shazow.net", "evildomain.example.com", "video.example"].contains(request.url?.host())
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if request.url?.absoluteString == PreviewFixtures.unreachableImageURL {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let path = request.url?.path() ?? ""
        let photo: Data? = if [PreviewFixtures.demoAvatarURL, PreviewFixtures.externalImageURL].contains(request.url?.absoluteString) || path == "/emoji/apron" {
            Self.icon()
        } else if path.hasPrefix("/emoji/") {
            Self.emoji(path.dropFirst("/emoji/".count))
        } else if path.contains("embed_1/") {
            Self.photo(CGSize(width: 1600, height: 1200), hue: 0.02)
        } else if path.contains("embed_6/") {
            Self.photo(CGSize(width: 1200, height: 630), hue: 0.58)
        } else if path.contains("embed_7/") {
            Self.photo(CGSize(width: 1200, height: 630), hue: 0.75)
        } else if path.contains("embed_9/") {
            Self.photo(CGSize(width: 1200, height: 630), hue: 0.95)
        } else {
            nil
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": photo == nil ? "application/octet-stream" : "image/jpeg"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: photo ?? Data("fixture".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// What this device would fetch for the busy room's bare wiki link.
    static let wikiPreview = LinkPreview(title: "Release 0.2 · ladle wiki", site: "git.example",
                                         image: photo(CGSize(width: 840, height: 440), hue: 0.33))

    /// A still life: a table, a wall, and a round enamel pot in the given hue.
    static func photo(_ size: CGSize, hue: CGFloat) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.85) { context in
            let c = context.cgContext
            UIColor(hue: 0.1, saturation: 0.15, brightness: 0.85, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            UIColor(hue: 0.08, saturation: 0.45, brightness: 0.45, alpha: 1).setFill()
            c.fill(CGRect(x: 0, y: size.height * 0.62, width: size.width, height: size.height * 0.38))
            let w = size.width * 0.42, h = size.height * 0.38
            let body = CGRect(x: (size.width - w) / 2, y: size.height * 0.34, width: w, height: h)
            UIColor(white: 0, alpha: 0.18).setFill()
            c.fillEllipse(in: CGRect(x: body.minX - 20, y: body.maxY - 30, width: w + 40, height: 60))
            UIColor(hue: hue, saturation: 0.8, brightness: 0.75, alpha: 1).setFill()
            c.fill(CGRect(x: body.minX, y: body.minY, width: w, height: h).insetBy(dx: 0, dy: 20))
            c.fillEllipse(in: CGRect(x: body.minX, y: body.maxY - 60, width: w, height: 80))
            UIColor(hue: hue, saturation: 0.85, brightness: 0.6, alpha: 1).setFill()
            c.fillEllipse(in: CGRect(x: body.minX - 10, y: body.minY - 10, width: w + 20, height: 60))
            UIColor.black.withAlphaComponent(0.75).setFill()
            c.fill(CGRect(x: size.width / 2 - 40, y: body.minY - 46, width: 80, height: 36))
            UIColor.white.withAlphaComponent(0.35).setFill()
            c.fillEllipse(in: CGRect(x: body.minX + w * 0.12, y: body.minY + 60, width: w * 0.12, height: h * 0.45))
        }
    }

    /// A server icon: a rust square with a cream bowl.
    static func icon() -> Data {
        let size = CGSize(width: 256, height: 256)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(red: 0.72, green: 0.33, blue: 0.2, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.98, green: 0.94, blue: 0.86, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 56, y: 96, width: 144, height: 104))
            context.fill(CGRect(x: 120, y: 40, width: 16, height: 80))
        }
    }

    /// The fixture catalog's other emoji: a parrot in motion (a still copy in grey) and a wide
    /// squirrel's hat.
    static func emoji(_ name: Substring) -> Data {
        let size = name == "shipit" ? CGSize(width: 128, height: 64) : CGSize(width: 128, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            let c = context.cgContext
            switch name {
            case "shipit":
                UIColor(red: 0.45, green: 0.3, blue: 0.2, alpha: 1).setFill()
                c.fillEllipse(in: CGRect(x: 8, y: 40, width: 112, height: 20))
                c.fill(CGRect(x: 36, y: 6, width: 56, height: 44))
            default:
                (name == "partyparrot" ? UIColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 1) : UIColor.gray).setFill()
                c.fillEllipse(in: CGRect(x: 14, y: 14, width: 100, height: 100))
                UIColor(red: 0.98, green: 0.7, blue: 0.1, alpha: 1).setFill()
                c.fill(CGRect(x: 84, y: 52, width: 36, height: 20))
            }
        }
    }

    /// The draft's files: two photos, a PDF, and one still being prepared.
    @MainActor
    static func stagedAttachments() -> [StagedFile] {
        let folder = URL.temporaryDirectory.appending(path: "ladle-shots-staged", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func file(_ name: String, _ data: Data, _ type: String, _ size: CGSize? = nil) -> StagedFile {
            let url = folder.appending(path: name)
            try? data.write(to: url)
            let attachment = Attachment(fileURL: url, title: name, contentType: type, byteCount: data.count,
                                        pixelWidth: size.map { Int($0.width) }, pixelHeight: size.map { Int($0.height) })
            return StagedFile(name: name, phase: .ready(attachment))
        }
        return [
            file("IMG_4021.jpg", photo(CGSize(width: 1200, height: 1600), hue: 0.58), "image/jpeg", CGSize(width: 1200, height: 1600)),
            file("IMG_4022.jpg", photo(CGSize(width: 1600, height: 1200), hue: 0.58), "image/jpeg", CGSize(width: 1600, height: 1200)),
            file("receipt-flea-market.pdf", Data(count: 48_213), "application/pdf"),
            StagedFile(name: "IMG_4023.HEIC", phase: .preparing),
        ]
    }
}
