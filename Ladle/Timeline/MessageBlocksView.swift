import ApronKit
import SwiftUI
import UIKit

/// A body's blocks (`MessageText.blocks`) as apron-web's message markdown shows them: paragraphs
/// and headings as `EmojiText`, quotes with a rule at their edge, lists with their bullets or
/// numbers, code (highlighted where `CodeHighlighter` knows its language) and tables scrolling
/// sideways inside the message rather than widening it, and each markdown image as a block under
/// the media gate. Text keeps the caller's role and color,
/// and follows Dynamic Type.
struct MessageBlocksView: View {
    let blocks: [MessageBlock]
    let catalog: EmojiCatalog?
    var role: TextRole = .body
    /// Where images may load from; without one (no server yet), an image is its alt text, linked.
    var gate: MediaGate?
    var settings: MediaSettings?

    var body: some View {
        stack(blocks)
    }

    private func stack(_ blocks: [MessageBlock]) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(block) }
        })
    }

    @ViewBuilder
    private func view(_ block: MessageBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text, role)
        case .heading(let level, let heading):
            inline(heading, level <= 2 ? .title : role).apText(level <= 2 ? .title : role, level == 1 ? .bold : .semibold)
                .accessibilityAddTraits(.isHeader)
        case .quote(let inner):
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                RoundedRectangle(cornerRadius: 1.5).fill(Palette.lineStrong).frame(width: 3)
                stack(inner).foregroundStyle(Palette.inkMuted)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s1) {
                        Text(ordered ? "\(start + index)." : "•").apText(role).monospacedDigit().foregroundStyle(Palette.inkMuted)
                            .accessibilityHidden(!ordered)
                        stack(item)
                    }
                }
            }
        case .code(let language, let code):
            ScrollView(.horizontal) {
                Text(CodeHighlighter.highlighted(code, fence: language).map(coloured) ?? AttributedString(code))
                    .apText(.ui, mono: true).foregroundStyle(Palette.ink)
                    .fixedSize()
                    .padding(Tokens.Space.s3)
            }
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        case .rule:
            Rectangle().fill(Palette.lineStrong).frame(height: 1).padding(.vertical, Tokens.Space.s1)
                .accessibilityHidden(true)
        case .table(let table):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { cells(table.header, table, header: true) }
                    Rectangle().fill(Palette.lineStrong).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                        GridRow { cells(row, table, header: false) }
                    }
                }
                .fixedSize()
            }
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        case .image(let image):
            MarkdownImageView(image: image, gate: gate, settings: settings)
        }
    }

    private func inline(_ text: AttributedString, _ role: TextRole) -> some View {
        EmojiText(text: styled(text), catalog: catalog, role: role)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A highlighted block in the theme's colors, as apron.css's `.hljs-*` rules.
    private func coloured(_ code: AttributedString) -> AttributedString {
        var out = code
        for (token, range) in code.runs[CodeTokenKey.self] {
            guard let token else { continue }
            switch token {
            case .comment:
                out[range].foregroundColor = Palette.inkMuted
                out[range].inlinePresentationIntent = .emphasized
            case .meta: out[range].foregroundColor = Palette.inkMuted
            case .keyword: out[range].foregroundColor = Palette.termMagenta
            case .string: out[range].foregroundColor = Palette.ok
            case .number: out[range].foregroundColor = Palette.warn
            case .title: out[range].foregroundColor = Palette.denim
            case .type: out[range].foregroundColor = Palette.accent
            case .attr: out[range].foregroundColor = Palette.termCyan
            case .addition:
                out[range].foregroundColor = Palette.ok
                out[range].backgroundColor = Palette.ok.opacity(0.16)
            case .deletion:
                out[range].foregroundColor = Palette.danger
                out[range].backgroundColor = Palette.danger.opacity(0.16)
            case .emphasis: out[range].inlinePresentationIntent = .emphasized
            case .strong: out[range].inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return out
    }

    private func cells(_ cells: [AttributedString], _ table: MessageTable, header: Bool) -> some View {
        ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
            let alignment: HorizontalAlignment = switch table.alignments[safe: column] {
            case .center: .center
            case .trailing: .trailing
            default: .leading
            }
            EmojiText(text: styled(cell), catalog: catalog, role: .ui)
                .apText(.ui, header ? .semibold : .regular)
                .padding(.horizontal, Tokens.Space.s3)
                .padding(.vertical, Tokens.Space.s2)
                .frame(minWidth: 48, maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
                .gridColumnAlignment(alignment)
        }
    }
}

/// A markdown image (`![alt](url)`) as a block: the image at its own shape where the gate lets it
/// load, a `MediaAskTile` where it waits for a tap, else its alt text as a link to it. An image
/// that fails to load (an unreachable host, not an image) shows a broken-image box with its alt.
struct MarkdownImageView: View {
    let image: MessageImage
    let gate: MediaGate?
    let settings: MediaSettings?

    var body: some View {
        let what = image.alt.isEmpty ? "Image" : image.alt
        switch gate?.decide(image.url) {
        case .load(let url)?:
            LoadedMarkdownImage(url: url, alt: image.alt)
        case .ask(let ask)? where settings != nil:
            MediaAskTile(ask: ask, what: what, settings: settings!)
        default:
            if ["http", "https"].contains(image.url.scheme?.lowercased() ?? "") {
                Link(image.alt.isEmpty ? image.url.absoluteString : image.alt, destination: image.url)
            } else {
                Text(image.alt)
            }
        }
    }
}

private struct LoadedMarkdownImage: View {
    let url: URL
    let alt: String
    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(MediaAskTile.width, image.size.width), maxHeight: Tokens.Size.embedMaxH, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
            } else {
                VStack(spacing: Tokens.Space.s1) {
                    if failed {
                        Image(systemName: "photo.badge.exclamationmark").font(.title2).foregroundStyle(Palette.inkMuted)
                        Text(alt.isEmpty ? "Image" : alt).apText(.ui, .semibold).foregroundStyle(Palette.ink).lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text("Couldn't load from \(url.host() ?? "its site")").apText(.sm).foregroundStyle(Palette.inkMuted)
                    } else {
                        ProgressView().tint(Palette.inkMuted)
                    }
                }
                .padding(Tokens.Space.s3)
                .frame(maxWidth: MediaAskTile.width, minHeight: 120)
                .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(Palette.line))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(failed ? "\(alt.isEmpty ? "Image" : alt), couldn't load" : alt.isEmpty ? "Image" : alt)
        .accessibilityAddTraits(.isImage)
        .task(id: url) {
            if let cached = MediaLoader.shared.cachedImage(url, maxPixel: 960) {
                image = cached
                return
            }
            do {
                let loaded = try await MediaLoader.shared.image(url, maxPixel: 960)
                withAnimation(Motion.fast(reduceMotion)) { image = loaded }
            } catch {
                failed = true
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
