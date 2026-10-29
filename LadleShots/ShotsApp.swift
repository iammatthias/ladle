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
    case emoji, emojiPicker = "emoji-picker", emojiShortcode = "emoji-shortcode"
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

        let store = await PreviewFixtures.makeStore()
        guard let home = store.session(for: PreviewFixtures.homeID) else { exit(1) }

        var shots: [(screen: Screen, style: UIUserInterfaceStyle, large: Bool)] = []
        for screen in Screen.allCases {
            shots.append((screen, .dark, false))
            shots.append((screen, .light, false))
        }
        shots.append((.timeline, .dark, true))

        for shot in shots {
            let size = shot.screen == .ipad ? pad : phone
            scene.sizeRestrictions?.minimumSize = .zero
            scene.sizeRestrictions?.maximumSize = size
            scene.sizeRestrictions?.minimumSize = size
            scene.windows.first?.overrideUserInterfaceStyle = shot.style
            show(AnyView(view(shot.screen, store: store, home: home, staged: staged)
                .environment(\.fixedTypeSize, shot.large ? .accessibility3 : .large)
                .environment(\.scenePhase, .inactive)
                .dynamicTypeSize(shot.large ? .accessibility3 : .large)
                .apronStyle()
                .id(UUID())))
            try? await Task.sleep(for: .milliseconds(shot.screen == .ipad ? 2500 : 1500))
            let name = "ladle-\(shot.screen.rawValue)-\(shot.large ? "ax3" : shot.style == .dark ? "dark" : "light").png"
            capture(scene, to: directory.appending(path: name))
        }
        writeContrast(to: directory.appending(path: "contrast.json"))
        exit(0)
    }

    static func view(_ screen: Screen, store: SessionStore, home: ServerSession, staged: [DraftAttachment]) -> AnyView {
        switch screen {
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
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.busyRoomID) })
        case .mention:
            AnyView(NavigationStack {
                TimelineView(session: home, roomID: PreviewFixtures.busyRoomID, draft: Draft(text: "Thanks @"))
            })
        case .members:
            AnyView(NavigationStack { MemberList(session: home, roomID: PreviewFixtures.busyRoomID) })
        case .reaction:
            AnyView(ReactionPicker { _ in })
        case .attachments:
            AnyView(NavigationStack {
                TimelineView(session: home, roomID: PreviewFixtures.mediaRoomID, draft: Draft(text: "Both sides of mine", attachments: staged))
            })
        case .media:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.mediaRoomID) })
        case .links:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.linkRoomID) })
        case .viewer:
            AnyView(MediaViewer(items: home.mediaItems(in: PreviewFixtures.mediaRoomID),
                                selection: home.mediaItems(in: PreviewFixtures.mediaRoomID).first?.id ?? ""))
        case .textLimit:
            AnyView(NavigationStack {
                TimelineView(session: home, roomID: PreviewFixtures.busyRoomID,
                             draft: Draft(text: String(repeating: "Release notes for 0.2, every change since August. ", count: 82) + "🎉"))
            })
        case .guestComposer:
            AnyView(NavigationStack {
                if let demo = store.session(for: PreviewFixtures.demoID) { TimelineView(session: demo, roomID: "lobby") }
            })
        case .emoji:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.emojiRoomID) })
        case .emojiPicker:
            AnyView(ReactionPicker(session: home) { _ in })
        case .emojiShortcode:
            AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.emojiRoomID, draft: Draft(text: "Lunch :pa")) })
        case .ipad:
            AnyView(SplitLayout(store: store, serverID: .constant(PreviewFixtures.homeID.uuidString),
                                roomID: .constant(PreviewFixtures.busyRoomID), place: .constant(nil), connecting: .constant(nil)))
        }
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

    /// WCAG 2 contrast of the text tokens on the grounds they sit on, per theme.
    static func writeContrast(to url: URL) {
        typealias C = Tokens.Color
        let pairs: [(String, Themed<RGBA>, Themed<RGBA>)] = [
            ("ink on timeline", C.ink, C.bg100), ("ink-muted on timeline", C.inkMuted, C.bg100),
            ("ink-muted on chrome", C.inkMuted, C.bg000), ("ink on raised", C.ink, C.bg200),
            ("on-accent on accent", C.onAccent, C.accent), ("accent on timeline", C.accent, C.bg100),
            ("denim on denim-soft", C.denim, C.denimSoft), ("denim on timeline", C.denim, C.bg100),
            ("ink on accent-soft", C.ink, C.accentSoft), ("private on private-soft", C.private, C.privateSoft),
            ("danger on timeline", C.danger, C.bg100),
        ]
        func luminance(_ rgb: UInt32) -> Double {
            func channel(_ value: UInt32) -> Double {
                let c = Double(value & 0xFF) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
        }
        func ratio(_ a: RGBA, _ b: RGBA) -> String {
            let (l1, l2) = (luminance(a.rgb), luminance(b.rgb))
            return String(format: "%.2f", (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05))
        }
        let report: [JSONValue] = pairs.map { name, text, ground in
            ["pair": .string(name), "dark": .number(ratio(text.dark, ground.dark)), "light": .number(ratio(text.light, ground.light))]
        }
        try? JSONValue.array(report).serializedData().write(to: url)
    }
}

/// Answers the fixtures' hosted files (`PreviewFixtures.fileURL`) with generated media, and
/// stages the composer's attachments, so the media screens render without a network.
final class FixtureMedia: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { ["home.example", "demo.apron.example"].contains(request.url?.host()) }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path() ?? ""
        let photo: Data? = if request.url?.absoluteString == PreviewFixtures.demoAvatarURL || path == "/emoji/apron" {
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
    static func stagedAttachments() -> [DraftAttachment] {
        let folder = URL.temporaryDirectory.appending(path: "ladle-shots-staged", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func file(_ name: String, _ data: Data, _ type: String, _ size: CGSize? = nil) -> DraftAttachment {
            let url = folder.appending(path: name)
            try? data.write(to: url)
            let attachment = Attachment(fileURL: url, title: name, contentType: type, byteCount: data.count,
                                        pixelWidth: size.map { Int($0.width) }, pixelHeight: size.map { Int($0.height) })
            return DraftAttachment(name: name, phase: .ready(attachment))
        }
        return [
            file("IMG_4021.jpg", photo(CGSize(width: 1200, height: 1600), hue: 0.58), "image/jpeg", CGSize(width: 1200, height: 1600)),
            file("IMG_4022.jpg", photo(CGSize(width: 1600, height: 1200), hue: 0.58), "image/jpeg", CGSize(width: 1600, height: 1200)),
            file("receipt-flea-market.pdf", Data(count: 48_213), "application/pdf"),
            DraftAttachment(name: "IMG_4023.HEIC", phase: .preparing),
        ]
    }
}
