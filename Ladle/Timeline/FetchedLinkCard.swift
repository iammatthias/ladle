import ApronKit
import ImageIO
import LinkPresentation
import SwiftUI
import UniformTypeIdentifiers

extension LinkPreviews {
    /// LadleShots swaps it for one that answers from fixtures.
    @MainActor static var shared = LinkPreviews(directory: URL.cachesDirectory.appending(path: "LinkPreviews", directoryHint: .isDirectory),
                                                fetch: fetchWithLinkPresentation)

    /// The `UserDefaults` key of the Show Link Previews switch in `Settings.bundle`.
    static let settingKey = "showLinkPreviews"

    /// LinkPresentation follows redirects and reads the page's title and image; this keeps the
    /// title, the final host as the site, and the image as a JPEG at most 840 px on its long side.
    /// A page without a title gives no preview.
    @MainActor static func fetchWithLinkPresentation(_ url: URL) async -> LinkPreview? {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        guard let metadata = try? await provider.startFetchingMetadata(for: url),
              let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        let host = (metadata.url ?? url).host() ?? url.host() ?? ""
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var image: Data?
        if let provider = metadata.imageProvider, let data = await imageData(provider) {
            image = await Task.detached { thumbnail(data, maxPixel: 840) }.value
        }
        return LinkPreview(title: title, site: site, image: image)
    }

    private static func imageData(_ provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(for: .image) { data, _ in continuation.resume(returning: data) }
        }
    }

    nonisolated private static func thumbnail(_ data: Data, maxPixel: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }
}

/// A link the server did not describe, as `LinkCard` with a preview this device fetched, when
/// Show Link Previews is on. It fetches when the row appears. Until a preview arrives, or when
/// none does, it shows `placeholder`: the embed's fallback card, or nothing for a link in the text.
/// `inset` is space above the card only, so a link without a preview takes no room.
struct FetchedLinkCard<Placeholder: View>: View {
    let url: URL
    var inset: CGFloat = 0
    let placeholder: Placeholder
    @AppStorage(LinkPreviews.settingKey) private var enabled = true
    @State private var loaded: (preview: LinkPreview, image: UIImage?)?

    init(url: URL, inset: CGFloat = 0, @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.inset = inset
        self.placeholder = placeholder()
        _loaded = State(initialValue: LinkPreviews.shared.cached(url).map(Self.decoded))
    }

    var body: some View {
        // A ZStack, not a Group: an empty Group would drop the task with its only child.
        ZStack(alignment: .leading) {
            if enabled, let loaded {
                LinkButton(url: url) {
                    LinkCard(site: loaded.preview.site, title: loaded.preview.title) {
                        if let image = loaded.image {
                            Color.clear
                                .aspectRatio(1.91, contentMode: .fit)
                                .overlay { Image(uiImage: image).resizable().scaledToFill() }
                                .clipped()
                                .accessibilityHidden(true)
                        }
                    }
                }
                .padding(.top, inset)
            } else {
                placeholder
            }
        }
        .task(id: enabled ? url : nil) {
            guard enabled, let preview = await LinkPreviews.shared.preview(for: url), loaded?.preview != preview else { return }
            loaded = Self.decoded(preview)
        }
    }

    private static func decoded(_ preview: LinkPreview) -> (preview: LinkPreview, image: UIImage?) {
        (preview, preview.image.flatMap(UIImage.init(data:)))
    }
}
