import ApronKit
import GameController
import SwiftUI
import UIKit

/// The design-review renderer. With `LADLE_SHOTS_DIR` set, it seeds `PreviewFixtures`, renders
/// every direction's four screens in light and dark plus one accessibility-size timeline, writes
/// a PNG per shot and `contrast.json`, and quits. AGENTS.md, "Design review", has the commands.
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
    case servers, rooms, timeline, composer
}

@MainActor
enum Renderer {
    static let size = CGSize(width: 393, height: 852)

    static func run(show: (AnyView) -> Void) async {
        guard let path = ProcessInfo.processInfo.environment["LADLE_SHOTS_DIR"],
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        else { return }
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scene.sizeRestrictions?.minimumSize = size
        scene.sizeRestrictions?.maximumSize = size
        scene.titlebar?.titleVisibility = .hidden
        scene.titlebar?.toolbar = nil

        // The Pass hint line shows only with a hardware keyboard, which connects after launch.
        for _ in 0 ..< 20 where GCKeyboard.coalesced == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let store = await PreviewFixtures.makeStore()
        guard let home = store.session(for: PreviewFixtures.homeID),
              let target = home.store.message(PreviewFixtures.replyTargetID)
        else { exit(1) }

        var shots: [(direction: Direction, screen: Screen, style: UIUserInterfaceStyle, large: Bool)] = []
        for direction in Direction.allCases {
            for screen in Screen.allCases {
                shots.append((direction, screen, .light, false))
                shots.append((direction, screen, .dark, false))
            }
            shots.append((direction, .timeline, .light, true))
        }

        for shot in shots {
            var theme = Theme.of(shot.direction)
            theme.fixedTypeSize = shot.large ? .accessibility3 : .large
            theme.applyNavigationAppearance()
            scene.windows.first?.overrideUserInterfaceStyle = shot.style
            let root: AnyView = switch shot.screen {
            case .servers:
                AnyView(ServerListView(store: store))
            case .rooms:
                AnyView(NavigationStack { RoomListView(session: home) })
            case .timeline:
                AnyView(NavigationStack { TimelineView(session: home, roomID: PreviewFixtures.busyRoomID) })
            case .composer:
                AnyView(NavigationStack {
                    TimelineView(session: home, roomID: PreviewFixtures.busyRoomID,
                                 draft: Draft(mode: .reply(target), text: "Looking now. Is it the bowl-only glyph?"))
                })
            }
            show(AnyView(root
                .themed(theme)
                .dynamicTypeSize(shot.large ? .accessibility3 : .large)
                .id(UUID())))
            try? await Task.sleep(for: .milliseconds(1500))
            let name = "\(shot.direction.rawValue)-\(shot.screen.rawValue)-\(shot.large ? "large" : shot.style == .dark ? "dark" : "light").png"
            capture(scene, to: directory.appending(path: name))
        }
        writeContrast(to: directory.appending(path: "contrast.json"))
        exit(0)
    }

    static func capture(_ scene: UIWindowScene, to url: URL) {
        guard let window = scene.windows.first else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: url)
    }

    /// WCAG 2 contrast of every text-bearing token pair, per direction and appearance.
    static func writeContrast(to url: URL) {
        func luminance(_ rgb: UInt32) -> Double {
            func channel(_ value: UInt32) -> Double {
                let c = Double(value & 0xFF) / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
        }
        func ratio(_ a: UInt32, _ b: UInt32) -> Double {
            let (l1, l2) = (luminance(a), luminance(b))
            return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
        }
        var report: [String: JSONValue] = [:]
        for direction in Direction.allCases {
            var pairs: [JSONValue] = []
            for pair in Theme.of(direction).palette.textPairs {
                pairs.append([
                    "pair": .string(pair.name),
                    "light": .number(String(format: "%.2f", ratio(pair.foreground.light, pair.background.light))),
                    "dark": .number(String(format: "%.2f", ratio(pair.foreground.dark, pair.background.dark))),
                ])
            }
            report[direction.rawValue] = .array(pairs)
        }
        try? JSONValue.object(report).serializedData().write(to: url)
    }
}
