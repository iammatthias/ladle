import Foundation
import UniformTypeIdentifiers

/// How a picked file is fitted to the server's stated media (EXT.md §6.1) before it is attached.
/// Without a stated category nothing is refused: a photo still becomes a JPEG within 2048 px and
/// 5 MB, and every other file goes as it is, for the server's 413 or 415 to decide.
public enum UploadPlan: Hashable, Sendable {
    /// Goes as it is, under its own type.
    case asIs
    /// Re-encoded as a still image of the target's type, scaled down and lower in quality until it fits.
    case image(ImageTarget)
    /// Re-encoded as AAC in an `.m4a` (`audio/mp4`), the only audio type iOS writes, at a bit rate
    /// that fits `maxBytes`.
    case audio(maxBytes: Int?)
    /// Exported at smaller presets as `type` (`video/mp4` or `video/quicktime`) until it fits.
    case video(type: String, maxBytes: Int?)
    case refused(String)

    public struct ImageTarget: Hashable, Sendable {
        /// `image/jpeg`, or `image/png` on a server that takes PNG but not JPEG.
        public var type: String
        public var maxBytes: Int
        public var maxSide: Int
    }

    public static let defaultMaxSide = 2048
    public static let defaultImageBytes = 5 * 1024 * 1024
    static let audioType = "audio/mp4"
    static let videoTypes = ["video/mp4", "video/quicktime"]

    /// The plan for a file of MIME `type` and `byteCount` under the server's `upload` category.
    public static func decide(type: String, byteCount: Int, limits: MediaLimits.Category?) -> UploadPlan {
        let type = type.lowercased()
        let verdict = MediaLimits.verdict(for: type, in: limits)
        if case .allowed(let stated) = verdict, stated.maxBytes.map({ byteCount <= $0 }) ?? true, !type.hasPrefix("image/") || type == "image/gif" {
            return .asIs
        }
        switch group(of: type) {
        case "image" where type != "image/gif":
            guard let target = imageTarget(limits) else { return .refused(refusal(type, limits)) }
            return .image(target)
        case "audio" where verdict != .unknown:
            guard case .allowed(let stated) = MediaLimits.verdict(for: audioType, in: limits) else { return .refused(refusal(type, limits)) }
            return .audio(maxBytes: stated.maxBytes)
        case "video" where verdict != .unknown:
            for exportType in videoTypes {
                if case .allowed(let stated) = MediaLimits.verdict(for: exportType, in: limits) { return .video(type: exportType, maxBytes: stated.maxBytes) }
            }
            return .refused(refusal(type, limits))
        default:
            return verdict == .unknown ? .asIs : .refused(refusal(type, limits, size: byteCount))
        }
    }

    /// JPEG where the server takes it or says nothing, else PNG, within the stated limits of that type.
    static func imageTarget(_ limits: MediaLimits.Category?) -> ImageTarget? {
        for type in ["image/jpeg", "image/png"] {
            switch MediaLimits.verdict(for: type, in: limits) {
            case .refused: continue
            case .unknown: return ImageTarget(type: type, maxBytes: defaultImageBytes, maxSide: defaultMaxSide)
            case .allowed(let stated):
                return ImageTarget(type: type, maxBytes: stated.maxBytes ?? defaultImageBytes, maxSide: min(defaultMaxSide, stated.maxSide ?? defaultMaxSide))
            }
        }
        return nil
    }

    /// Why a file of `type` can't go: the server takes no such files, or none this large.
    static func refusal(_ type: String, _ limits: MediaLimits.Category?, size: Int? = nil) -> String {
        let noun = noun(of: type)
        if case .allowed(let stated) = MediaLimits.verdict(for: type, in: limits), let maxBytes = stated.maxBytes, size.map({ $0 > maxBytes }) ?? true {
            return "This server takes \(noun) up to \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .binary))."
        }
        let offer = UploadOffer(limits)
        if offer.takes(group: group(of: type)) { return "This server doesn't take \(type) files." }
        guard let summary = offer.summary, offer.images || offer.videos || offer.audio || offer.otherFiles else {
            return "This server doesn't take \(noun)."
        }
        return "\(summary.dropLast()), not \(noun)."
    }

    static func noun(of type: String) -> String {
        ["image": "images", "video": "videos", "audio": "audio", "text": "text files"][group(of: type)] ?? "files of this type"
    }

    static func group(of type: String) -> String {
        type.split(separator: "/").first.map(String.init) ?? ""
    }
}

/// The bit rate and sample rate a voice clip or a sound is re-encoded at, as AAC, mono.
public struct AudioEncoding: Hashable, Sendable {
    public var bitRate: Int
    public var sampleRate: Int

    /// From the best to the least that still carries speech.
    public static let steps = [
        AudioEncoding(bitRate: 64_000, sampleRate: 44_100),
        AudioEncoding(bitRate: 48_000, sampleRate: 44_100),
        AudioEncoding(bitRate: 32_000, sampleRate: 32_000),
        AudioEncoding(bitRate: 24_000, sampleRate: 24_000),
        AudioEncoding(bitRate: 16_000, sampleRate: 16_000),
    ]

    /// The best step whose `seconds` of audio fit `maxBytes`, leaving a tenth for the container.
    /// Nil when even the least is too large: the recording is too long for this server.
    public static func fitting(maxBytes: Int?, seconds: Double) -> AudioEncoding? {
        guard let maxBytes else { return steps[0] }
        return steps.first { Double($0.bitRate) / 8 * seconds <= Double(maxBytes) * 0.9 }
    }
}

/// What the attach menu offers, from the server's `upload` category (EXT.md §6.1: the picker
/// offers the patterns of `upload`, unless one of them is `*/*`). Without a category, everything.
public struct UploadOffer: Hashable, Sendable {
    public var images: Bool
    public var videos: Bool
    public var audio: Bool
    /// Types outside images, video and audio, such as documents.
    public var otherFiles: Bool
    /// The types the file picker shows: the stated ones, and every image, sound or video when
    /// Ladle can turn it into a type the server takes.
    public var contentTypes: [UTType]

    public init(_ category: MediaLimits.Category?) {
        guard let category, !category.keys.contains("*/*") else {
            (images, videos, audio, otherFiles, contentTypes) = (true, true, true, true, [.item])
            return
        }
        let groups = Set(category.keys.map(UploadPlan.group(of:)))
        images = groups.contains("image")
        videos = groups.contains("video")
        audio = groups.contains("audio")
        otherFiles = !groups.subtracting(["image", "video", "audio"]).isEmpty
        let allows = { (type: String) in MediaLimits.verdict(for: type, in: category) != .refused }
        var types: [UTType] = []
        if UploadPlan.imageTarget(category) != nil { types.append(.image) }
        if allows(UploadPlan.audioType) { types.append(.audio) }
        if UploadPlan.videoTypes.contains(where: allows) { types.append(.movie) }
        let broad = ["image": UTType.image, "video": .movie, "audio": .audio, "text": .text]
        for pattern in category.keys.sorted() {
            let parts = pattern.split(separator: "/").map(String.init)
            if let group = broad[parts[0]], types.contains(group) { continue }
            let type = parts.last == "*" ? broad[parts[0]] ?? .data : UTType(mimeType: pattern)
            if let type, !types.contains(type) { types.append(type) }
        }
        contentTypes = types
    }

    public func takes(group: String) -> Bool {
        switch group {
        case "image": images
        case "video": videos
        case "audio": audio
        default: otherFiles
        }
    }

    /// "This server takes images and audio only.", or nil when it takes every kind.
    public var summary: String? {
        let kinds = [(images, "images"), (videos, "videos"), (audio, "audio"), (otherFiles, "other files")]
        let taken = kinds.filter(\.0).map(\.1)
        guard taken.count < kinds.count else { return nil }
        guard !taken.isEmpty else { return "This server takes no files." }
        return "This server takes \(ListFormatter.localizedString(byJoining: taken)) only."
    }
}
