import ApronKit
import SwiftUI
import UIKit

/// A `terminal` embed (v10 §4.8.6), as apron-web's EmbedTerminal: a card titled by the embed's
/// title (else "Terminal") over its 80-column screen, scaled so the columns fit the message's
/// width, its rows down to the last one written. Until its write starts it has no `url` and
/// says "Waiting to stream…". While the embed has `url` it is live
/// under a Live badge, the screen following `url` (`ServerSession.follow`); then "Ended", and
/// once a snapshot carries `output`, that, as "Finished". A tap on the screen, or Expand, opens
/// it full screen in `TerminalViewer`. It only reads: nothing typed reaches it.
struct TerminalEmbedView: View {
    let session: ServerSession
    let embed: Embed
    @State private var expanded = false

    var body: some View {
        let live = session.liveText(of: embed)
        let screen = live?.screen ?? FinishedTerminals.screen(embed.output ?? "")
        let isLive = live?.isLive == true
        let status = Self.status(embed: embed, live: live)
        VStack(alignment: .leading, spacing: 0) {
            header(isLive: isLive, status: status)
            TerminalScreenView(screen: screen, rows: screen.shownRowCount, fit: .inline)
                .padding(.horizontal, Tokens.Space.s2)
                .padding(.bottom, Tokens.Space.s2)
                .contentShape(Rectangle())
                .onTapGesture { expanded = true }
                .accessibilityHidden(true)
        }
        .background(Palette.rail, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(isLive ? "Live" : status)")
        .accessibilityValue(screen.plainText)
        .accessibilityAction(named: "Expand Terminal") { expanded = true }
        .task(id: live.map(ObjectIdentifier.init)) {
            if let live { await session.follow(live) }
        }
        .fullScreenCover(isPresented: $expanded) {
            TerminalViewer(title: title, embed: embed, session: session)
        }
    }

    private var title: String { embed.title ?? "Terminal" }

    /// What a terminal that isn't live says, as apron-web's: Finished with its `output`, Ended
    /// once `GET url` ended or was refused, Waiting to stream… before its write starts (no
    /// `url`, §4.8.5), Unavailable with a `url` it may not read.
    static func status(embed: Embed, live: LiveText?) -> String {
        if embed.output != nil { return "Finished" }
        if live != nil { return "Ended" }
        return embed.isWaitingForWriter ? "Waiting to stream…" : "Unavailable"
    }

    private func header(isLive: Bool, status: String) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            Label(title, systemImage: "terminal")
                .apText(.sm, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
            if isLive {
                LiveBadge()
            } else {
                Text(status).apText(.xs).foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 0)
            Button { expanded = true } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.inkMuted)
                    .touchTarget()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand Terminal")
        }
        .padding(.leading, Tokens.Space.s3)
        .padding(.trailing, Tokens.Space.s1)
    }
}

/// apron-web's Live badge: a red dot and "Live", the dot pulsing unless Reduce Motion is on.
struct LiveBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        HStack(spacing: Tokens.Space.s1) {
            Circle().fill(Palette.danger).frame(width: 6, height: 6).opacity(dim ? 0.35 : 1)
            Text("Live").apText(.xs, .semibold).foregroundStyle(Palette.danger)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
        }
    }
}

/// Finished terminals' screens by their output, so a row drawn again doesn't parse it again.
@MainActor
enum FinishedTerminals {
    private static var kept: [String: TerminalScreen] = [:]
    private static var order: [String] = []

    static func screen(_ output: String) -> TerminalScreen {
        if let screen = kept[output] { return screen }
        let screen = TerminalScreen.showing(output)
        kept[output] = screen
        order.append(output)
        if order.count > 32 { kept[order.removeFirst()] = nil }
        return screen
    }

    /// The viewer's screen for finished output: with scrollback, made when it opens.
    static func viewerScreen(_ output: String) -> TerminalScreen {
        TerminalScreen.showing(output, scrollback: TerminalScreen.viewerScrollback)
    }
}

/// How a screen's font fits its space, as apron-web's `TerminalFit`: in a message, the 80
/// columns in the width at 4 to 13 pt; full screen, the largest size that fits the columns in
/// the width and the 40 rows in the height, but the rows never take it below 13 pt and the
/// columns never below 9 pt, the screen scrolling inside the viewer where it doesn't fit.
enum TerminalFit: Equatable {
    case inline
    case viewer(CGSize)

    var range: ClosedRange<CGFloat> { self == .inline ? 4...13 : 9...24 }
}

/// The screen's rows, drawn in the theme's mono face from the theme's colors, as apron-web's
/// `terminalTheme`: the rail's ground and ink, the 16 colors from the status tokens and the
/// terminal tokens, 256 and true colors as they are.
struct TerminalScreenView: View {
    let screen: TerminalScreen
    let rows: Int
    let fit: TerminalFit
    var scrollback = false
    @State private var width: CGFloat = 0

    var body: some View {
        let face = Self.face(width: width, fit: fit)
        let lines = (scrollback ? screen.scrollback : []) + Array(screen.screen.prefix(rows))
        VStack(alignment: .leading, spacing: 0) {
            if fit == .inline {
                // The width offered, not the screen's own, which follows the font this sets.
                Color.clear.frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            }
            ForEach(lines.indices, id: \.self) { index in
                Text(Self.attributed(lines[index], face: face))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(height: face.lineHeight, alignment: .leading)
            }
        }
        .frame(width: fit == .inline ? nil : face.advance * CGFloat(TerminalScreen.columns), alignment: .leading)
        .environment(\.layoutDirection, .leftToRight)
    }

    struct Face {
        var size: CGFloat
        var regular: UIFont
        var bold: UIFont
        /// Box drawing and block elements, from a face that draws them a whole cell wide, so
        /// lines and bars join: the theme's mono face may not have them, and a fallback's are narrower.
        var drawing: UIFont
        var advance: CGFloat
        var lineHeight: CGFloat
    }

    static func monoFont(size: CGFloat, weight: Font.Weight) -> UIFont {
        BundledFonts.themeFont(ActiveTheme.shared.theme.fonts.mono, size: size, weight: weight)
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: weight.ui)
    }

    /// The largest size in the fit's range whose 80 columns fit `width`, in quarter points.
    static func face(width: CGFloat, fit: TerminalFit) -> Face {
        let key = "\(width) \(fit) \(ActiveTheme.shared.theme.fonts.mono)"
        if let made = faces[key] { return made }
        let made = makeFace(width: width, fit: fit)
        if faces.count > 16 { faces = [:] }
        faces[key] = made
        return made
    }

    /// Faces made, by width, fit and theme face: a live screen redraws often.
    private static var faces: [String: Face] = [:]

    private static func makeFace(width: CGFloat, fit: TerminalFit) -> Face {
        let probe = monoFont(size: 100, weight: .regular)
        let ratio = ("W" as NSString).size(withAttributes: [.font: probe]).width / 100
        var fitted = width > 0 ? width / (CGFloat(TerminalScreen.columns) * ratio) : fit.range.lowerBound
        if case .viewer(let space) = fit, space.width > 0 {
            let inner = CGSize(width: space.width - Tokens.Space.s3 * 2, height: space.height - Tokens.Space.s3 * 2)
            let line = probe.lineHeight / 100
            fitted = min(inner.width / (CGFloat(TerminalScreen.columns) * ratio), max(13, inner.height / (CGFloat(TerminalScreen.rows) * line)))
        }
        let size = min(fit.range.upperBound, max(fit.range.lowerBound, (fitted * 4).rounded(.down) / 4))
        let regular = monoFont(size: size, weight: .regular)
        let drawing = UIFont(name: "Menlo-Regular", size: size * ratio / 0.602) ?? regular
        return Face(size: size, regular: regular, bold: monoFont(size: size, weight: .bold), drawing: drawing, advance: ratio * size,
                    lineHeight: ceil(regular.lineHeight))
    }

    /// One row as styled runs: cells of one style join into one run.
    static func attributed(_ row: [TerminalCell], face: Face) -> AttributedString {
        var out = AttributedString()
        var run = ""
        var style: TerminalStyle?
        var drawn = false
        func flush() {
            guard let style, !run.isEmpty else { return }
            var part = AttributedString(run)
            let (foreground, background) = colors(style)
            part.uiKit.font = drawn ? face.drawing : style.attributes.contains(.bold) ? face.bold : face.regular
            if style.attributes.contains(.italic), !drawn {
                part.uiKit.font = UIFont(descriptor: (part.uiKit.font ?? face.regular).fontDescriptor.withSymbolicTraits(.traitItalic)
                    ?? face.regular.fontDescriptor, size: face.size)
            }
            part.foregroundColor = style.attributes.contains(.dim) ? foreground.opacity(0.55) : foreground
            if let background { part.backgroundColor = background }
            if style.attributes.contains(.underline) { part.underlineStyle = .single }
            if style.attributes.contains(.strikethrough) { part.strikethroughStyle = .single }
            out += part
        }
        for cell in row where !cell.isContinuation {
            let drawing = cell.text.unicodeScalars.first.map { (0x2500...0x259F).contains($0.value) } ?? false
            if cell.style != style || drawing != drawn {
                flush()
                run = ""
                style = cell.style
                drawn = drawing
            }
            run += cell.text.isEmpty ? " " : cell.text
        }
        flush()
        return out
    }

    /// A cell's ink and ground; nil ground is the screen's own.
    static func colors(_ style: TerminalStyle) -> (Color, Color?) {
        var foreground = color(style.foreground) ?? Palette.ink
        var background = color(style.background)
        if style.attributes.contains(.inverse) {
            (foreground, background) = (background ?? Palette.rail, foreground)
        }
        if style.attributes.contains(.hidden) { foreground = background ?? Palette.rail }
        return (foreground, background)
    }

    private static func color(_ color: TerminalColor) -> Color? {
        switch color {
        case .default:
            return nil
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .indexed(let index):
            if let (r, g, b) = TerminalColor.xterm(index) {
                return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
            }
            switch index % 8 {
            case 0: return index == 8 ? Palette.inkMuted : Palette.lineStrong
            case 1: return Palette.danger
            case 2: return Palette.ok
            case 3: return Palette.warn
            case 4: return Palette.denim
            case 5: return Palette.termMagenta
            case 6: return Palette.termCyan
            default: return Palette.ink
            }
        }
    }
}

/// apron-web's TerminalViewer: the terminal full screen on the image viewer's dark ground, its
/// title, Live or how it stopped, and Close, over the 80 by 40 screen at a readable size (at
/// least 9 pt, scrolling sideways where 80 columns don't fit), keeping up to 5,000 lines that
/// scrolled off the top to scroll back through. It shows what the message shows, live too,
/// from the same read of `url`, and stays at the newest line until scrolled away from it.
struct TerminalViewer: View {
    let title: String
    let embed: Embed
    let session: ServerSession
    @Environment(\.dismiss) private var dismiss
    @State private var opened: LiveText?
    @State private var space: CGSize = .zero

    var body: some View {
        let live = session.liveText(of: embed)
        let screen = live?.viewerScreen ?? FinishedTerminals.viewerScreen(embed.output ?? live?.text ?? "")
        let isLive = live?.isLive == true
        VStack(spacing: 0) {
            HStack(spacing: Tokens.Space.s2) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).apText(.field, .semibold).foregroundStyle(Palette.viewerInk).lineLimit(1)
                    if isLive { LiveBadge() } else {
                        Text(TerminalEmbedView.status(embed: embed, live: live)).apText(.sm).foregroundStyle(Palette.viewerInkMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Palette.viewerInk)
                        .frame(width: Tokens.Control.xl, height: Tokens.Control.xl)
                        .background(Palette.viewerControl, in: Circle())
                        .touchTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.vertical, Tokens.Space.s3)
            // Opens at the newest line and follows it; a screen shorter than the viewer sits at its top.
            ScrollView([.vertical, .horizontal]) {
                TerminalScreenView(screen: screen, rows: TerminalScreen.rows, fit: .viewer(space), scrollback: true)
                    .padding(Tokens.Space.s3)
            }
            .defaultScrollAnchor(.bottomLeading, for: .initialOffset)
            .defaultScrollAnchor(.bottomLeading, for: .sizeChanges)
            .defaultScrollAnchor(.topLeading, for: .alignment)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { space = $0 }
            .background(Palette.rail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Terminal output")
            .accessibilityValue(screen.plainText)
        }
        .background(Palette.viewerGround.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear {
            opened = live
            live?.openViewer()
        }
        .onDisappear { opened?.closeViewer() }
        .task(id: live.map(ObjectIdentifier.init)) {
            if let live { await session.follow(live) }
        }
    }
}
