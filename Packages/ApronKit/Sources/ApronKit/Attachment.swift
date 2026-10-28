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

/// Fits a picked file to the server before it is attached, as apron-web does (EXT.md §6.1).
///
/// A still photo is re-encoded as JPEG, which also drops its metadata (location included), no
/// larger than 2048 px or the server's `max_side`, stepping the quality down to fit `max_bytes`
/// or a 5 MB aim. HEIC becomes JPEG because servers describe only PNG, JPEG, GIF and WebP as
/// images. A PNG already within the limits and every other file (GIF, video, audio, documents)
/// go as they are, refused up front only when the server's stated media rule them out.
public enum AttachmentPreparer {
    public static let defaultMaxSide = 2048
    public static let defaultImageBytes = 5 * 1024 * 1024

    /// Writes the prepared file under `directory` and returns it. `title` is the picked name;
    /// `contentType` is the picker's MIME type when it knows better than the extension.
    public static func prepare(_ source: URL, title: String, contentType: String? = nil, limits: MediaLimits.Category?,
                               into directory: URL) throws -> Attachment {
        let type = contentType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: source.pathExtension) ?? .data
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if type.conforms(to: .image), !type.conforms(to: .gif), let image = try reencodeIfNeeded(source, type: type, title: title,
                                                                                                  limits: limits, into: folder) {
            return image
        }
        let mime = contentType ?? type.preferredMIMEType ?? "application/octet-stream"
        let size = try byteCount(of: source)
        try check(size: size, type: mime, limits: limits)
        let destination = folder.appending(path: safeName(title))
        try FileManager.default.copyItem(at: source, to: destination)
        let pixels = type.conforms(to: .image) ? pixelSize(of: destination) : nil
        return Attachment(fileURL: destination, title: title, contentType: mime, byteCount: size,
                          pixelWidth: pixels?.width, pixelHeight: pixels?.height)
    }

    /// Nil when the file can go as it is: a PNG within the limits.
    private static func reencodeIfNeeded(_ source: URL, type: UTType, title: String, limits: MediaLimits.Category?,
                                         into folder: URL) throws -> Attachment? {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), let pixels = pixelSize(of: image) else {
            throw AttachmentError.unreadable
        }
        let jpegLimits: MediaLimits.Limits
        switch MediaLimits.verdict(for: "image/jpeg", in: limits) {
        case .refused: throw AttachmentError.refused("This server doesn't take photos.")
        case .unknown: jpegLimits = MediaLimits.Limits()
        case .allowed(let stated): jpegLimits = stated
        }
        let maxSide = min(defaultMaxSide, jpegLimits.maxSide ?? defaultMaxSide)
        let maxBytes = jpegLimits.maxBytes ?? defaultImageBytes
        if type.conforms(to: .png), max(pixels.width, pixels.height) <= maxSide,
           let size = try? byteCount(of: source), size <= maxBytes,
           MediaLimits.verdict(for: "image/png", in: limits) != .refused {
            return nil
        }
        var side = min(maxSide, max(pixels.width, pixels.height))
        while side >= 256 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            guard let scaled = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { throw AttachmentError.unreadable }
            for quality in [0.85, 0.7, 0.55, 0.4] {
                guard let data = jpeg(scaled, quality: quality) else { throw AttachmentError.unreadable }
                if data.count <= maxBytes {
                    let name = (title as NSString).deletingPathExtension + ".jpg"
                    let destination = folder.appending(path: safeName(name))
                    try data.write(to: destination)
                    return Attachment(fileURL: destination, title: name, contentType: "image/jpeg", byteCount: data.count,
                                      pixelWidth: scaled.width, pixelHeight: scaled.height)
                }
            }
            side = side * 3 / 4
        }
        throw AttachmentError.refused("This photo can't be made small enough for this server.")
    }

    /// Refuses a file the server's stated media rule out, naming the limit.
    static func check(size: Int, type: String, limits: MediaLimits.Category?) throws {
        let group = type.split(separator: "/").first.map(String.init) ?? "file"
        let noun = ["image": "images", "video": "videos", "audio": "audio", "text": "text files"][group] ?? "files of this type"
        switch MediaLimits.verdict(for: type, in: limits) {
        case .unknown:
            return
        case .refused:
            throw AttachmentError.refused("This server doesn't take \(noun).")
        case .allowed(let stated):
            if let maxBytes = stated.maxBytes, size > maxBytes {
                let limit = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)
                throw AttachmentError.refused("This server takes \(noun) up to \(limit).")
            }
        }
    }

    static func byteCount(of url: URL) throws -> Int {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw AttachmentError.unreadable }
        return size
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
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
