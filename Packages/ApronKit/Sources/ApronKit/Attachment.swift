import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file ready to send as an `upload` embed (§4.8.4): on disk, with the name it goes out under
/// (the embed's `title`) and the type its write declares (EXT.md §6: the `Content-Type`).
public struct Attachment: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var fileURL: URL
    public var title: String
    public var contentType: String
    public var byteCount: Int
    /// Pixel size of an image, as sent.
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(id: UUID = UUID(), fileURL: URL, title: String, contentType: String, byteCount: Int,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.contentType = contentType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var isImage: Bool { contentType.hasPrefix("image/") }
    public var isVideo: Bool { contentType.hasPrefix("video/") }
    public var isAudio: Bool { contentType.hasPrefix("audio/") }
}

/// Why a file cannot be attached.
public enum AttachmentError: Error, Hashable, Sendable, LocalizedError {
    case unreadable
    /// The server's stated media (EXT.md §6) rule the file out; the text says which limit.
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "This file can't be read."
        case .refused(let reason): reason
        }
    }
}

/// Carries out an `UploadPlan` for a picked file, as apron-web does (EXT.md §6.1). A still photo
/// is re-encoded, which also drops its metadata (location included): as JPEG, or PNG where the
/// server takes no JPEG, within the plan's side and size. HEIC must become JPEG because servers
/// describe only PNG, JPEG, GIF and WebP as images. A PNG already within the limits goes as it is.
/// Audio and video are re-encoded by the app (AVFoundation), which hands the result back here.
public enum AttachmentPreparer {
    /// The MIME type a picked file goes out under: the picker's when it knows better than the
    /// file's extension.
    public static func contentType(of source: URL, declared: String?) -> String {
        if let declared { return declared }
        guard let type = UTType(filenameExtension: source.pathExtension) else { return "application/octet-stream" }
        // `.m4a` files say `audio/x-m4a`; servers list AAC in MPEG-4 as `audio/mp4`.
        if type.conforms(to: .mpeg4Audio) { return "audio/mp4" }
        return type.preferredMIMEType ?? "application/octet-stream"
    }

    /// The type a picked file goes out under, and what fitting it to the server takes.
    public static func plan(for source: URL, declared: String?, limits: MediaLimits.Category?) throws -> (type: String, plan: UploadPlan) {
        let type = contentType(of: source, declared: declared)
        return (type, UploadPlan.decide(type: type, byteCount: try byteCount(of: source), limits: limits))
    }

    /// Writes the prepared file under `directory` and returns it. `title` is the picked name;
    /// `contentType` is the picker's MIME type when it knows better than the extension. A sound
    /// or video that still needs re-encoding is refused as too large.
    public static func prepare(_ source: URL, title: String, contentType: String? = nil, limits: MediaLimits.Category?,
                               into directory: URL) throws -> Attachment {
        let (mime, plan) = try plan(for: source, declared: contentType, limits: limits)
        let size = try byteCount(of: source)
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch plan {
        case .refused(let reason):
            throw AttachmentError.refused(reason)
        case .audio, .video:
            throw AttachmentError.refused(UploadPlan.refusal(mime, limits, size: size))
        case .image(let target):
            if let image = try reencodeIfNeeded(source, type: mime, size: size, title: title, target: target, limits: limits, into: folder) {
                return image
            }
        case .asIs:
            break
        }
        let destination = folder.appending(path: safeName(title))
        try FileManager.default.copyItem(at: source, to: destination)
        let pixels = mime.hasPrefix("image/") ? pixelSize(of: destination) : nil
        return Attachment(fileURL: destination, title: title, contentType: mime, byteCount: size,
                          pixelWidth: pixels?.width, pixelHeight: pixels?.height)
    }

    /// An avatar (§4.8.6) as apron-web makes one (EXT.md §6.1): the middle square of the image,
    /// 512 px or the server's `max_side` if smaller, as JPEG (or PNG where the server's avatars
    /// take no JPEG) within `max_bytes` or 256 KB, and 256 px when 512 does not fit.
    public static func prepareAvatar(_ source: URL, limits: MediaLimits.Category?, into directory: URL) throws -> Attachment {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let full = CGImageSourceCreateThumbnailAtIndex(image, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary)
        else { throw AttachmentError.unreadable }
        guard let target = UploadPlan.imageTarget(limits) else { throw AttachmentError.refused("This server doesn't take photos as avatars.") }
        let stated: MediaLimits.Limits
        if case .allowed(let limits) = MediaLimits.verdict(for: target.type, in: limits) { stated = limits } else { stated = MediaLimits.Limits() }
        let side = min(full.width, full.height)
        guard let square = full.cropping(to: CGRect(x: (full.width - side) / 2, y: (full.height - side) / 2, width: side, height: side)) else {
            throw AttachmentError.unreadable
        }
        let maxBytes = stated.maxBytes ?? 262_144
        let format: UTType = target.type == "image/png" ? .png : .jpeg
        let name = format == .png ? "avatar.png" : "avatar.jpg"
        for side in [512, 256].map({ min($0, stated.maxSide ?? $0, side) }) {
            guard let scaled = scale(square, to: side) else { throw AttachmentError.unreadable }
            for data in encodings(of: scaled, as: format) where data.count <= maxBytes {
                let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appending(path: name)
                try data.write(to: destination)
                return Attachment(fileURL: destination, title: name, contentType: target.type, byteCount: data.count,
                                  pixelWidth: side, pixelHeight: side)
            }
        }
        throw AttachmentError.refused("This image can't be made small enough for an avatar.")
    }

    private static func scale(_ image: CGImage, to side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    /// Nil when the file can go as it is: a PNG within the limits of a server that takes PNG.
    private static func reencodeIfNeeded(_ source: URL, type: String, size: Int, title: String, target: UploadPlan.ImageTarget,
                                         limits: MediaLimits.Category?, into folder: URL) throws -> Attachment? {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), let pixels = pixelSize(of: image) else {
            throw AttachmentError.unreadable
        }
        if type == "image/png", max(pixels.width, pixels.height) <= target.maxSide, size <= target.maxBytes,
           MediaLimits.verdict(for: "image/png", in: limits) != .refused {
            return nil
        }
        let format: UTType = target.type == "image/png" ? .png : .jpeg
        let name = (title as NSString).deletingPathExtension + (format == .png ? ".png" : ".jpg")
        for side in sides(from: min(target.maxSide, max(pixels.width, pixels.height))) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { throw AttachmentError.unreadable }
            for data in encodings(of: scaled, as: format) where data.count <= target.maxBytes {
                let destination = folder.appending(path: safeName(name))
                try data.write(to: destination)
                return Attachment(fileURL: destination, title: name, contentType: target.type, byteCount: data.count,
                                  pixelWidth: scaled.width, pixelHeight: scaled.height)
            }
        }
        throw AttachmentError.refused("This photo can't be made small enough for this server.")
    }

    /// The longest sides tried, largest first: three quarters of the last each time, down to 256 px.
    static func sides(from start: Int) -> [Int] {
        Array(sequence(first: start) { $0 * 3 / 4 }.prefix { $0 >= 256 })
    }

    /// The image encoded at each quality step, best first; PNG has only one.
    private static func encodings(of image: CGImage, as format: UTType) -> some Sequence<Data> {
        (format == .png ? [1.0] : [0.85, 0.7, 0.55, 0.4]).lazy.compactMap { encode(image, as: format, quality: $0) }
    }

    static func byteCount(of url: URL) throws -> Int {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw AttachmentError.unreadable }
        return size
    }

    private static func encode(_ image: CGImage, as format: UTType, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(pixelSize(of:))
    }

    /// Display size, with the EXIF orientation applied.
    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width) : (width, height)
    }

    /// A file name without path separators, never empty.
    static func safeName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty || cleaned.hasPrefix(".") ? "file" + cleaned : cleaned
    }
}
