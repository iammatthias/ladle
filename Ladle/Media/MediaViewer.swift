import ApronKit
import SwiftUI
import UIKit

/// An image upload in a room, as the media viewer pages through them.
struct MediaItem: Identifiable, Hashable {
    let id: String
    /// What the viewer shows: `og.image`.
    let media: URL
    /// The file itself, the embed's `url`, for Open Original.
    let original: URL?
    let name: String
    let alt: String?
    let sender: String
    let date: Date

    /// A message's embed by position, stable across snapshots of the message.
    static func id(_ message: MessageSnapshot, _ index: Int) -> String { "\(message.messageID.text)#\(index)" }
}

extension ServerSession {
    /// Every loadable image upload in a room, oldest first, as the web's viewer pages them.
    func mediaItems(in roomID: String) -> [MediaItem] {
        let policy = mediaPolicy
        return timeline(roomID).filter { !$0.isTombstone }.flatMap { message in
            message.embedList.enumerated().compactMap { index, embed -> MediaItem? in
                guard case .image(let image) = embed.upload, policy.allowsMedia(image.url) else { return nil }
                return MediaItem(id: MediaItem.id(message, index), media: image.url,
                                 original: embed.url.flatMap { policy.allowsMedia($0) ? $0 : nil },
                                 name: embed.name ?? "Image", alt: image.alt, sender: displayName(for: message.from), date: message.date)
            }
        }
    }
}

/// The web's MediaViewer, as a full-screen photo viewer: dark whatever the theme, the image's
/// name, who sent it and when, a count, Open Original and Close. Swipe pages through the room's
/// images, oldest first, as the web's arrows do; pinch or double-tap zooms, as a browser does.
struct MediaViewer: View {
    let items: [MediaItem]
    @State var selection: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = items.first { $0.id == selection }
        VStack(spacing: 0) {
            bar(current)
            TabView(selection: $selection) {
                ForEach(items) { item in
                    ZoomablePage(url: item.media, label: item.alt ?? item.name).tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Palette.viewerGround.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private func bar(_ item: MediaItem?) -> some View {
        HStack(spacing: Tokens.Space.s2) {
            Button { dismiss() } label: { glyph("xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 0) {
                Text(item?.name ?? "").apText(.field, .semibold).foregroundStyle(Palette.viewerInk).lineLimit(1).truncationMode(.middle)
                if let item {
                    Text("\(item.sender), \(item.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                        .apText(.sm).foregroundStyle(Palette.viewerInkMuted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if items.count > 1, let index = items.firstIndex(where: { $0.id == selection }) {
                Text("\(index + 1) of \(items.count)").apText(.ui).monospacedDigit().foregroundStyle(Palette.viewerInkMuted)
            }
            if let original = item?.original {
                Link(destination: original) { glyph("safari") }
                    .accessibilityLabel("Open Original")
            }
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s3)
    }

    private func glyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.viewerInk)
            .frame(width: Tokens.Control.xl, height: Tokens.Control.xl)
            .background(Palette.viewerControl, in: Circle())
            .touchTarget()
    }
}

/// An image that fills the page, zoomed with a pinch or a double tap.
private struct ZoomablePage: View {
    let url: URL
    let label: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                ZoomableImage(image: image)
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(.isImage)
            } else if failed {
                Label("Couldn't load the image", systemImage: "photo").foregroundStyle(Palette.viewerInkMuted)
            } else {
                ProgressView().tint(Palette.viewerInk)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            do { image = try await MediaLoader.shared.image(url, maxPixel: 2048) } catch { failed = true }
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomView { ZoomView() }

    func updateUIView(_ view: ZoomView, context: Context) {
        view.imageView.image = image
    }
}

/// A scroll view that zooms its image from 1x to 4x, and toggles 2.5x where a double tap lands.
private final class ZoomView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == minimumZoomScale, imageView.frame.size != bounds.size {
            imageView.frame = bounds
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: !UIAccessibility.isReduceMotionEnabled)
        } else {
            let point = recognizer.location(in: imageView)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                 animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}
