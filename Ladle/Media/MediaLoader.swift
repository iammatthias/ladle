import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// Loads embed media and files over HTTP: images decoded at the size they show, and files
/// saved under their names for Quick Look. Callers check `MediaPolicy`
/// first; this never decides what may load. No cookies go out, and the URL cache is the app's.
@MainActor
final class MediaLoader {
    /// LadleShots swaps it for one that answers from fixtures.
    static var shared = MediaLoader(configuration: .default)

    private let session: URLSession
    private let images = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage, any Error>] = [:]

    init(configuration: URLSessionConfiguration) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        session = URLSession(configuration: configuration)
        images.totalCostLimit = 96 << 20
    }

    private static func key(_ url: URL, _ maxPixel: CGFloat) -> String { "\(Int(maxPixel))|\(url.absoluteString)" }

    func cachedImage(_ url: URL, maxPixel: CGFloat) -> UIImage? {
        images.object(forKey: Self.key(url, maxPixel) as NSString)
    }

    /// The image no larger than `maxPixel` on its long side, decoded off the main thread.
    func image(_ url: URL, maxPixel: CGFloat) async throws -> UIImage {
        let key = Self.key(url, maxPixel)
        if let cached = images.object(forKey: key as NSString) { return cached }
        if let running = inFlight[key] { return try await running.value }
        let session = session
        let task = Task<UIImage, any Error> {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) { throw URLError(.badServerResponse) }
            return try await Task.detached { try Self.decode(data, maxPixel: maxPixel) }.value
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let image = try await task.value
        images.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4))
        return image
    }

    nonisolated private static func decode(_ data: Data, maxPixel: CGFloat) throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw URLError(.cannotDecodeContentData) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
        return UIImage(cgImage: image)
    }

    /// The file saved as `name` in the caches directory, downloaded once.
    func file(_ url: URL, named name: String) async throws -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let folder = URL.cachesDirectory.appending(path: "Media/\(digest)", directoryHint: .isDirectory)
        let destination = folder.appending(path: name.replacingOccurrences(of: "/", with: "-"))
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) { return destination }
        let (temporary, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

/// A remote image in a box of known shape: the ground and a spinner while it loads, so the
/// timeline never jumps, then the image fades in.
struct RemoteImage: View {
    let url: URL
    var maxPixel: CGFloat = 960
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Palette.raised
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
            } else if failed {
                Image(systemName: "photo").imageScale(.large).foregroundStyle(Palette.inkMuted)
            } else {
                ProgressView().tint(Palette.inkMuted)
            }
        }
        .clipped()
        .task(id: url) {
            if let cached = MediaLoader.shared.cachedImage(url, maxPixel: maxPixel) {
                image = cached
                return
            }
            do {
                let loaded = try await MediaLoader.shared.image(url, maxPixel: maxPixel)
                withAnimation(Motion.fast(reduceMotion)) { image = loaded }
            } catch {
                failed = true
            }
        }
    }
}
