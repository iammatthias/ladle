import ApronKit
import SwiftUI
import UIKit

/// The design-review renderer. With `LADLE_SHOTS_DIR` set, it seeds `PreviewFixtures`, renders
/// each screen the web-parity pairs compare at iPhone size (390x844) in dark and light, the
/// timeline at AX3, and the iPad split view (1180x820) in dark and light, writes a PNG per shot
/// and `contrast.json`, and quits. AGENTS.md, "Design review", has the commands.
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
    case servers, connect, rooms, timeline, mention, members, reaction, ipad
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
            show(AnyView(view(shot.screen, store: store, home: home)
                .environment(\.fixedTypeSize, shot.large ? .accessibility3 : .large)
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

    static func view(_ screen: Screen, store: SessionStore, home: ServerSession) -> AnyView {
        switch screen {
        case .servers:
            AnyView(NavigationStack { ServerListView(store: store, open: { _ in }, connecting: .constant(nil)) })
        case .connect:
            AnyView(ConnectView(store: store, prefill: TokenPayload(token: "", server: URL(string: "wss://chat.example/ws"))))
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
        case .ipad:
            AnyView(SplitLayout(store: store, serverID: .constant(PreviewFixtures.homeID.uuidString),
                                roomID: .constant(PreviewFixtures.busyRoomID), connecting: .constant(nil)))
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
