import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers
import XCTest
@testable import ApronKit

final class EmbedTests: XCTestCase {
    func testAnUploadIsPendingUntilItsURLThenTakesItsKindFromOG() throws {
        let pending = try XCTUnwrap(Embed(["embed_id": "e1", "kind": "upload", "title": "before.png"]))
        XCTAssertEqual(pending.upload, .pending)
        XCTAssertEqual(pending.name, "before.png")

        let image = try XCTUnwrap(Embed([
            "embed_id": "e1", "kind": "upload", "title": "before.png", "url": "https://chat.example/f/Zr8",
            "og": ["title": "before.png", "image": ["url": "https://chat.example/f/Zr8/thumb", "type": "image/webp", "width": 320, "height": 180, "alt": "Dashboard"]],
        ]))
        guard case .image(let media) = image.upload else { return XCTFail("expected an image, got \(String(describing: image.upload))") }
        XCTAssertEqual(media.url.absoluteString, "https://chat.example/f/Zr8/thumb")
        XCTAssertEqual(media.aspectRatio, 320.0 / 180.0)
        XCTAssertEqual(media.alt, "Dashboard")

        let video = Embed(["kind": "upload", "url": "https://chat.example/f/v", "og": ["video": ["url": "https://chat.example/f/v", "type": "video/mp4"]]])
        XCTAssertEqual(video?.upload, .video(try XCTUnwrap(OpenGraph.Media(["url": "https://chat.example/f/v", "type": "video/mp4"]))))
        let audio = Embed(["kind": "upload", "url": "https://chat.example/f/a", "og": ["audio": ["url": "https://chat.example/f/a"]]])
        guard case .audio = audio?.upload else { return XCTFail("expected audio") }
        let file = Embed(["kind": "upload", "title": "report.pdf", "url": "https://chat.example/f/r"])
        XCTAssertEqual(file?.upload, .file(URL(string: "https://chat.example/f/r")!))
    }

    func testOtherKindsAndUnsafeURLsAreKeptOutOfTheModel() throws {
        XCTAssertNil(Embed(["title": "no kind"]))
        let iframe = try XCTUnwrap(Embed(["kind": "iframe", "url": "javascript:alert(1)", "height": 300]))
        XCTAssertNil(iframe.upload)
        XCTAssertNil(iframe.url, "only http and https links")
        XCTAssertEqual(iframe.json["height"], 300)
        let message = MessageSnapshot(messageID: LogID("1")!, logID: LogID("1")!, roomID: "r", from: UserObject(["user_id": "a"])!,
                                      body: ["text": "", "embeds": [["kind": "upload"], "junk", ["kind": "link"]]])
        XCTAssertEqual(message.embedList.map(\.kind), ["upload", "link"])
    }
}

final class MediaPolicyTests: XCTestCase {
    private func server(_ ext: JSONValue? = nil, capabilities: [JSONValue] = ["embed:upload"]) -> ServerInfo? {
        var params: [String: JSONValue] = ["apron": 9, "auth": ["guest"], "capabilities": .array(capabilities)]
        if let ext { params["ext"] = ext }
        return ServerInfo(params: .object(params))
    }

    func testALinkCardPlaysOGVideoThenAudioOnlyWhereThePolicyAllowsIt() throws {
        let policy = MediaPolicy(serverURL: URL(string: "wss://chat.example/ws")!, server: server())
        func og(_ fields: JSONValue) throws -> OpenGraph { try XCTUnwrap(OpenGraph(fields)) }
        let image: JSONValue = ["url": "https://chat.example/f/p/thumb", "width": 640, "height": 360]
        let video: JSONValue = ["url": "https://chat.example/f/p/v.mp4", "type": "video/mp4", "width": 640, "height": 360]
        let audio: JSONValue = ["url": "https://chat.example/f/p/a.m4a", "type": "audio/mp4"]

        guard case .video(let played, let poster)? = try og(["image": image, "video": video, "audio": audio]).player(policy: policy) else {
            return XCTFail("video wins over audio")
        }
        XCTAssertEqual(played.aspectRatio, 640.0 / 360.0)
        XCTAssertEqual(poster?.url.absoluteString, "https://chat.example/f/p/thumb")

        guard case .audio(let sound, let cover)? = try og(["image": image, "audio": audio]).player(policy: policy) else {
            return XCTFail("audio without video")
        }
        XCTAssertEqual(sound.url.absoluteString, "https://chat.example/f/p/a.m4a")
        XCTAssertNotNil(cover)

        XCTAssertNil(try og(["image": image]).player(policy: policy), "an image alone stays the image card")
        let elsewhere: JSONValue = ["url": "https://cdn.example/v.mp4"]
        XCTAssertNil(try og(["image": image, "video": elsewhere]).player(policy: policy), "other origins do not load")
        XCTAssertEqual(try og(["image": image, "audio": audio, "video": elsewhere]).player(policy: policy),
                       .audio(try XCTUnwrap(OpenGraph.Media(audio)), cover: try XCTUnwrap(OpenGraph.Media(image))), "an unplayable video falls back to the audio")
        guard case .video(_, let none)? = try og(["video": video, "image": ["url": "https://cdn.example/p.jpg"]]).player(policy: policy) else {
            return XCTFail("video without an allowed poster")
        }
        XCTAssertNil(none)
        let inline = "data:image/png;base64,AAAA"
        XCTAssertNil(try og(["video": ["url": .string(inline)]]).player(policy: policy), "an inline image is no player")
    }

    func testMediaLoadsFromTheServersOwnOriginAndTheOnesItNames() {
        let policy = MediaPolicy(serverURL: URL(string: "wss://chat.example/ws")!, server: server())
        XCTAssertEqual(policy.origin, "https://chat.example")
        XCTAssertTrue(policy.allowsMedia(URL(string: "https://chat.example/files/e1/s")!))
        XCTAssertTrue(policy.allowsMedia(URL(string: "https://CHAT.example:443/files/e1/s")!))
        XCTAssertFalse(policy.allowsMedia(URL(string: "http://chat.example/files/e1/s")!))
        XCTAssertFalse(policy.allowsMedia(URL(string: "https://tracker.example/pixel.png")!))
        XCTAssertTrue(policy.allowsMedia(URL(string: "data:image/png;base64,iVBORw0KGgo=")!))
        XCTAssertTrue(policy.allowsAvatar(URL(string: "https://gravatar.example/a.png")!))
        XCTAssertFalse(policy.allowsAvatar(URL(string: "http://elsewhere.example/a.png")!))

        let local = MediaPolicy(serverURL: URL(string: "ws://127.0.0.1:8080/ws")!, server: server())
        XCTAssertTrue(local.allowsMedia(URL(string: "http://127.0.0.1:8080/files/e1/s")!))
        XCTAssertFalse(local.allowsMedia(URL(string: "http://127.0.0.1:9090/files/e1/s")!))

        let named = server(["media": ["origins": ["https://media.chat.example", "https://x.example/path", "http://evil.example", "http://localhost:9000"]]],
                           capabilities: ["embed:upload", "ext:media"])
        let bucket = MediaPolicy(serverURL: URL(string: "wss://chat.example/ws")!, server: named)
        XCTAssertEqual(bucket.trustedOrigins, ["https://media.chat.example", "http://localhost:9000"])
        XCTAssertTrue(bucket.allowsMedia(URL(string: "https://media.chat.example/f/1")!))
        XCTAssertFalse(MediaPolicy(serverURL: URL(string: "wss://chat.example/ws")!, server: server(named?.ext)).allowsMedia(URL(string: "https://media.chat.example/f/1")!),
                       "origins count only with capability ext:media")
    }

    func testTheMostSpecificPatternGivesAFilesLimits() throws {
        let info = server(["media": [
            "upload": ["image/*": ["max_bytes": 5_242_880, "max_side": 2048], "IMAGE/GIF": ["max_bytes": 1000], "audio/*": [:],
                       "bad": ["max_bytes": 1], "video/mp4": "nope", "text/plain": ["max_bytes": -3]],
            "emoji": ["*/*": ["max_bytes": 9], "image/png": ["max_bytes": 262_144]],
        ]], capabilities: ["ext:media"])
        let limits = try XCTUnwrap(MediaLimits(server: info))
        XCTAssertNil(limits.avatar)
        XCTAssertEqual(MediaLimits.verdict(for: "image/png", in: limits.emoji), .allowed(.init(maxBytes: 262_144)))
        XCTAssertEqual(MediaLimits.verdict(for: "image/gif", in: limits.emoji), .allowed(.init(maxBytes: 9)), "*/* when nothing nearer matches")
        XCTAssertEqual(MediaLimits.verdict(for: "image/gif", in: limits.upload), .allowed(.init(maxBytes: 1000)))
        XCTAssertEqual(MediaLimits.verdict(for: "image/jpeg", in: limits.upload), .allowed(.init(maxBytes: 5_242_880, maxSide: 2048)))
        XCTAssertEqual(MediaLimits.verdict(for: "audio/mp4; codecs=mp4a", in: limits.upload), .allowed(.init()))
        XCTAssertEqual(MediaLimits.verdict(for: "text/plain", in: limits.upload), .allowed(.init()), "a non-positive limit is ignored")
        XCTAssertEqual(MediaLimits.verdict(for: "video/mp4", in: limits.upload), .refused)
        XCTAssertEqual(MediaLimits.verdict(for: "video/mp4", in: limits.avatar), .unknown)
        XCTAssertNil(MediaLimits(server: server()), "nothing is known without ext:media")
    }
}

final class AttachmentPreparerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ladle-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A noisy image, so JPEG cannot shrink it to nothing, with GPS and an orientation.
    private func photo(width: Int, height: Int, type: UTType, orientation: Int = 1) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        var generator = SystemRandomNumberGenerator()
        for _ in 0 ..< 4000 {
            context.setFillColor(CGColor(red: .random(in: 0 ... 1, using: &generator), green: .random(in: 0 ... 1, using: &generator), blue: 0.5, alpha: 1))
            context.fill(CGRect(x: .random(in: 0 ..< width), y: .random(in: 0 ..< height), width: 40, height: 40))
        }
        let image = try XCTUnwrap(context.makeImage())
        let url = directory.appending(path: "IMG_0001." + (type.preferredFilenameExtension ?? "img"))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.37, kCGImagePropertyGPSLatitudeRef: "N"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    func testAPhotoBecomesAJPEGWithinTheSideLimitWithoutItsLocation() throws {
        let source = try photo(width: 3000, height: 2000, type: .heic, orientation: 6)
        let attachment = try AttachmentPreparer.prepare(source, title: "IMG_0001.HEIC", limits: nil, into: directory)
        XCTAssertEqual(attachment.title, "IMG_0001.jpg")
        XCTAssertEqual(attachment.contentType, "image/jpeg")
        XCTAssertEqual([attachment.pixelWidth, attachment.pixelHeight], [1366, 2048], "rotated upright, long side 2048")
        let written = try properties(attachment.fileURL)
        XCTAssertNil(written[kCGImagePropertyGPSDictionary], "location dropped")
        XCTAssertEqual(written[kCGImagePropertyPixelHeight] as? Int, 2048)
        XCTAssertEqual(attachment.byteCount, try Data(contentsOf: attachment.fileURL).count)
    }

    func testThePhotoShrinksToTheServersStatedLimits() throws {
        let source = try photo(width: 1600, height: 1200, type: .jpeg)
        let limits: MediaLimits.Category = ["image/*": .init(maxBytes: 60_000, maxSide: 800)]
        let attachment = try AttachmentPreparer.prepare(source, title: "a.jpeg", limits: limits, into: directory)
        XCTAssertLessThanOrEqual(attachment.byteCount, 60_000)
        XCTAssertLessThanOrEqual(max(attachment.pixelWidth ?? 0, attachment.pixelHeight ?? 0), 800)
    }

    func testAnAvatarIsTheMiddleSquareAt512Pixels() throws {
        let source = try photo(width: 1200, height: 800, type: .heic)
        let avatar = try AttachmentPreparer.prepareAvatar(source, limits: nil, into: directory)
        XCTAssertEqual(avatar.contentType, "image/jpeg")
        XCTAssertEqual([avatar.pixelWidth, avatar.pixelHeight], [512, 512])
        XCTAssertLessThanOrEqual(avatar.byteCount, 262_144)
        let written = try properties(avatar.fileURL)
        XCTAssertEqual(written[kCGImagePropertyPixelWidth] as? Int, 512)
        XCTAssertNil(written[kCGImagePropertyGPSDictionary])
        let small = try AttachmentPreparer.prepareAvatar(source, limits: ["image/*": .init(maxSide: 128)], into: directory)
        XCTAssertEqual(small.pixelWidth, 128)
    }

    func testAPNGWithinTheLimitsGoesAsItIs() throws {
        let source = try photo(width: 300, height: 200, type: .png)
        let attachment = try AttachmentPreparer.prepare(source, title: "Screenshot.png", limits: nil, into: directory)
        XCTAssertEqual(attachment.contentType, "image/png")
        XCTAssertEqual(attachment.title, "Screenshot.png")
        XCTAssertEqual(try Data(contentsOf: attachment.fileURL), try Data(contentsOf: source))
        XCTAssertEqual([attachment.pixelWidth, attachment.pixelHeight], [300, 200])
    }

    func testAPhotoBecomesAPNGWithinTheLimitsWhereTheServerTakesOnlyPNG() throws {
        let source = try photo(width: 1600, height: 1200, type: .jpeg)
        let attachment = try AttachmentPreparer.prepare(source, title: "a.jpeg", limits: ["image/png": .init(maxBytes: 400_000)], into: directory)
        XCTAssertEqual(attachment.contentType, "image/png")
        XCTAssertEqual(attachment.title, "a.png")
        XCTAssertLessThanOrEqual(attachment.byteCount, 400_000)
        XCTAssertEqual(try properties(attachment.fileURL)[kCGImagePropertyPixelWidth] as? Int, attachment.pixelWidth)
    }

    func testAnAvatarFitsCloudflaresAvatarLimit() throws {
        let source = try photo(width: 3000, height: 2000, type: .heic)
        let avatars: MediaLimits.Category = ["image/png": .init(maxBytes: 262_144), "image/jpeg": .init(maxBytes: 262_144)]
        let avatar = try AttachmentPreparer.prepareAvatar(source, limits: avatars, into: directory)
        XCTAssertEqual(avatar.contentType, "image/jpeg")
        XCTAssertLessThanOrEqual(avatar.byteCount, 262_144)
        let png = try AttachmentPreparer.prepareAvatar(source, limits: ["image/png": .init(maxBytes: 262_144)], into: directory)
        XCTAssertEqual([png.contentType, png.title], ["image/png", "avatar.png"])
        XCTAssertLessThanOrEqual(png.byteCount, 262_144)
    }

    func testASoundOrVideoStillTooLargeAfterReencodingIsRefused() throws {
        let source = directory.appending(path: "talk.m4a")
        try Data(repeating: 1, count: 4096).write(to: source)
        XCTAssertThrowsError(try AttachmentPreparer.prepare(source, title: "talk.m4a", limits: ["audio/mp4": .init(maxBytes: 1024)], into: directory)) {
            XCTAssertEqual($0 as? AttachmentError, .refused("This server takes audio up to 1 KB."))
        }
    }

    func testOtherFilesGoAsTheyAreUnlessTheServersMediaRuleThemOut() throws {
        let source = directory.appending(path: "clip.mov")
        try Data(repeating: 7, count: 4096).write(to: source)
        let attachment = try AttachmentPreparer.prepare(source, title: "clip.mov", limits: nil, into: directory)
        XCTAssertEqual(attachment.contentType, "video/quicktime")
        XCTAssertEqual(attachment.byteCount, 4096)

        XCTAssertThrowsError(try AttachmentPreparer.prepare(source, title: "clip.mov", limits: ["video/*": .init(maxBytes: 1024)], into: directory)) {
            XCTAssertEqual($0 as? AttachmentError, .refused("This server takes videos up to 1 KB."))
        }
        XCTAssertThrowsError(try AttachmentPreparer.prepare(source, title: "clip.mov", limits: ["image/*": .init()], into: directory)) {
            XCTAssertEqual($0 as? AttachmentError, .refused("This server takes images only, not videos."))
        }
        let notes = directory.appending(path: "notes")
        try Data("hi".utf8).write(to: notes)
        XCTAssertEqual(try AttachmentPreparer.prepare(notes, title: "notes", limits: nil, into: directory).contentType, "application/octet-stream")
    }
}

/// What Ladle does with each kind of file under a server's stated media, Cloudflare's demo first.
final class UploadPlanTests: XCTestCase {
    /// `ext.media.upload` of server.apron.chat (apron-server-cloudflare SPEC §4).
    static let cloudflare: MediaLimits.Category = Dictionary(uniqueKeysWithValues: [
        "image/png", "image/jpeg", "image/gif", "image/webp", "audio/webm", "audio/ogg", "audio/mp4",
    ].map { ($0, MediaLimits.Limits(maxBytes: 5_242_880)) })
    let mb = 1_048_576

    func testOnCloudflarePhotosShrinkSoundsBecomeM4AAndVideosAndDocumentsAreRefused() {
        let cf = Self.cloudflare
        XCTAssertEqual(UploadPlan.decide(type: "image/heic", byteCount: 3 * mb, limits: cf),
                       .image(.init(type: "image/jpeg", maxBytes: 5_242_880, maxSide: 2048)))
        XCTAssertEqual(UploadPlan.decide(type: "image/gif", byteCount: mb, limits: cf), .asIs)
        XCTAssertEqual(UploadPlan.decide(type: "image/gif", byteCount: 6 * mb, limits: cf), .refused("This server takes images up to 5 MB."))
        XCTAssertEqual(UploadPlan.decide(type: "audio/mp4", byteCount: mb, limits: cf), .asIs)
        XCTAssertEqual(UploadPlan.decide(type: "audio/mp4", byteCount: 6 * mb, limits: cf), .audio(maxBytes: 5_242_880))
        XCTAssertEqual(UploadPlan.decide(type: "audio/mpeg", byteCount: mb, limits: cf), .audio(maxBytes: 5_242_880), "MP3 is not on the list")
        XCTAssertEqual(UploadPlan.decide(type: "video/quicktime", byteCount: mb, limits: cf),
                       .refused("This server takes images and audio only, not videos."))
        XCTAssertEqual(UploadPlan.decide(type: "application/pdf", byteCount: 1000, limits: cf),
                       .refused("This server takes images and audio only, not files of this type."))
    }

    func testAVideoIsCompressedToATypeTheServerTakes() {
        let limits: MediaLimits.Category = ["video/mp4": .init(maxBytes: 10 * mb)]
        XCTAssertEqual(UploadPlan.decide(type: "video/mp4", byteCount: 9 * mb, limits: limits), .asIs)
        XCTAssertEqual(UploadPlan.decide(type: "video/mp4", byteCount: 11 * mb, limits: limits), .video(type: "video/mp4", maxBytes: 10 * mb))
        XCTAssertEqual(UploadPlan.decide(type: "video/quicktime", byteCount: mb, limits: limits), .video(type: "video/mp4", maxBytes: 10 * mb))
        XCTAssertEqual(UploadPlan.decide(type: "video/mp4", byteCount: 11 * mb, limits: ["video/quicktime": .init()]),
                       .video(type: "video/quicktime", maxBytes: nil))
    }

    func testWithoutStatedMediaOnlyPhotosChange() {
        XCTAssertEqual(UploadPlan.decide(type: "image/jpeg", byteCount: 9 * mb, limits: nil),
                       .image(.init(type: "image/jpeg", maxBytes: 5 * mb, maxSide: 2048)))
        for type in ["image/gif", "video/quicktime", "audio/x-wav", "application/pdf"] {
            XCTAssertEqual(UploadPlan.decide(type: type, byteCount: 900 * mb, limits: nil), .asIs, type)
        }
    }

    func testPhotosBecomePNGWhereTheServerTakesNoJPEGAndAreRefusedWhereItTakesNeither() {
        XCTAssertEqual(UploadPlan.decide(type: "image/jpeg", byteCount: mb, limits: ["image/png": .init(maxBytes: mb, maxSide: 1024)]),
                       .image(.init(type: "image/png", maxBytes: mb, maxSide: 1024)))
        XCTAssertEqual(UploadPlan.decide(type: "image/jpeg", byteCount: mb, limits: ["image/webp": .init()]),
                       .refused("This server doesn't take image/jpeg files."))
        XCTAssertEqual(UploadPlan.decide(type: "audio/mpeg", byteCount: mb, limits: ["audio/ogg": .init()]),
                       .refused("This server doesn't take audio/mpeg files."), "iOS writes no Ogg")
    }

    func testAudioTakesTheBestBitRateThatFits() {
        XCTAssertEqual(AudioEncoding.fitting(maxBytes: nil, seconds: 7200)?.bitRate, 64_000)
        XCTAssertEqual(AudioEncoding.fitting(maxBytes: 5_242_880, seconds: 300)?.bitRate, 64_000)
        XCTAssertEqual(AudioEncoding.fitting(maxBytes: 5_242_880, seconds: 600)?.bitRate, 48_000)
        XCTAssertEqual(AudioEncoding.fitting(maxBytes: 5_242_880, seconds: 1800)?.bitRate, 16_000)
        XCTAssertNil(AudioEncoding.fitting(maxBytes: 5_242_880, seconds: 3600), "too long even at 16 kbit/s")
    }

    func testTheAttachMenuOffersWhatTheServerTakes() {
        let cf = UploadOffer(Self.cloudflare)
        XCTAssertEqual([cf.images, cf.videos, cf.audio, cf.otherFiles], [true, false, true, false])
        XCTAssertEqual(cf.summary, "This server takes images and audio only.")
        XCTAssertEqual(cf.contentTypes.first, .image)
        XCTAssertTrue(cf.contentTypes.contains(.audio), "any sound, since it can become audio/mp4")
        XCTAssertFalse(cf.contentTypes.contains { $0.conforms(to: .movie) })

        let open = UploadOffer(nil)
        XCTAssertEqual([open.images, open.videos, open.audio, open.otherFiles], [true, true, true, true])
        XCTAssertNil(open.summary)
        XCTAssertEqual(open.contentTypes, [.item])
        XCTAssertEqual(UploadOffer(["*/*": .init(maxBytes: 1)]).contentTypes, [.item])
        XCTAssertEqual(UploadOffer([:]).summary, "This server takes no files.")
    }
}

/// The write side of `send` and `setAvatar` (§4.8.3), against a fake connection and a fake PUT.
@MainActor
final class UploadSessionTests: XCTestCase {
    struct Write: Equatable {
        var url: String
        var title: String
        var contentType: String
    }

    /// Records each PUT; a title starting with `big` is refused with 413, and every write waits
    /// at half way until `release()`.
    final class FakeWrites: Sendable {
        let writes = Mutex<[Write]>([])
        let released = Mutex(false)

        func write(_ url: URL, _ attachment: Attachment, _ progress: @escaping @Sendable (Double) -> Void) async throws {
            writes.withLock { $0.append(Write(url: url.absoluteString, title: attachment.title, contentType: attachment.contentType)) }
            if attachment.title.hasPrefix("big") { throw EmbedWriteError.tooLarge }
            progress(0.5)
            while !released.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
            progress(1)
        }

        func release() { released.withLock { $0 = true } }
        var recorded: [Write] { writes.withLock { $0 } }
    }

    let writes = FakeWrites()
    var session: ServerSession!
    var socket: FakeTransport!

    override func setUp() async throws {
        let counter = Mutex(0)
        let socket = FakeTransport()
        self.socket = socket
        let writes = writes
        let environment = ServerSession.Environment(
            makeTransport: { _ in socket },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } },
            writeEmbed: { try await writes.write($0, $1, $2) }
        )
        session = ServerSession(record: ServerRecord(url: URL(string: "wss://chat.example/ws")!), tokens: InMemoryTokenStore(), environment: environment)
        session.start()
        await socket.deliver(["method": "server", "params": [
            "apron": 9, "auth": ["guest"], "capabilities": ["rooms", "command", "embed:upload"],
        ]])
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.guest(name: nil)) }
        await eventually("auth and room_list sent") { await socket.sentLog.count == 2 }
        await socket.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await socket.deliver(["id": "c2", "result": ["joined": [["room_id": "general"]]]])
        _ = try await signIn.value
    }

    override func tearDown() async throws {
        await session.stop()
    }

    private func attachment(_ title: String, _ type: String = "image/jpeg") -> Attachment {
        Attachment(fileURL: URL(filePath: "/tmp/\(title)"), title: title, contentType: type, byteCount: 10)
    }

    private func sent(_ index: Int) async -> String {
        await eventually("frame \(index)") { await socket.sentLog.count > index }
        return await socket.sentLog[index]
    }

    func testAttachmentsGoAsUploadEmbedsAndAreWrittenToTheirURLsInOrder() async throws {
        session.post("Before the fix:", in: "general", attachments: [attachment("before.jpg"), attachment("notes.pdf", "application/pdf")])
        let frame = await sent(2)
        XCTAssertEqual(frame, #"{"id":"q-c3","method":"message","params":{"body":{"embeds":[{"kind":"upload","title":"before.jpg"},{"kind":"upload","title":"notes.pdf"}],"format":"plain","text":"Before the fix:"},"room_id":"general"}}"#)
        await socket.deliver(["id": "q-c3", "result": ["message_id": "500", "embeds": [
            ["embed_id": "e1", "kind": "upload", "write_url": "https://chat.example/write/t1"],
            ["embed_id": "e2", "kind": "upload", "write_url": "https://chat.example/write/t2"],
        ]]])
        await eventually("both writes half way") { session.uploadProgress == ["e1": 0.5, "e2": 0.5] }
        XCTAssertTrue(session.outbox.isEmpty, "the message is sent; the writes follow on their own")
        XCTAssertEqual(Set(writes.recorded.map(\.url)), ["https://chat.example/write/t1", "https://chat.example/write/t2"])
        XCTAssertEqual(writes.recorded.first { $0.url.hasSuffix("t1") }, Write(url: "https://chat.example/write/t1", title: "before.jpg", contentType: "image/jpeg"))
        XCTAssertEqual(writes.recorded.first { $0.url.hasSuffix("t2") }?.title, "notes.pdf")
        writes.release()
        await eventually("finished") { session.uploadProgress.isEmpty }
        XCTAssertTrue(session.outbox.isEmpty)
    }

    func testARefusedWriteComesBackAsNotSentAndRetriesAsItsOwnMessage() async throws {
        writes.release()
        session.post("", in: "general", attachments: [attachment("big.mov", "video/quicktime")])
        _ = await sent(2)
        await socket.deliver(["id": "q-c3", "result": ["message_id": "500", "embeds": [
            ["embed_id": "e1", "kind": "upload", "write_url": "https://chat.example/write/t1"],
        ]]])
        await eventually("not sent") { session.outbox.count == 1 && session.outbox[0].state != .sending }
        let item = session.outbox[0]
        XCTAssertEqual(item.state, .failed("The file is larger than this server accepts."))
        XCTAssertEqual(item.attachments.map(\.title), ["big.mov"])
        XCTAssertEqual(item.text, "")
        XCTAssertTrue(session.uploadProgress.isEmpty)

        session.retry(item.id)
        let again = await sent(3)
        XCTAssertEqual(again, #"{"id":"q-c4","method":"message","params":{"body":{"embeds":[{"kind":"upload","title":"big.mov"}],"format":"plain","text":""},"room_id":"general"}}"#)
    }

    func testAResultWithoutWriteURLsLeavesTheAttachmentNotSent() async throws {
        session.post("hi", in: "general", attachments: [attachment("a.jpg")])
        _ = await sent(2)
        await socket.deliver(["id": "q-c3", "result": ["message_id": "500"]])
        await eventually("not sent") { session.outbox.first?.state == .failed("The server didn't accept the attachment.") }
        XCTAssertTrue(writes.recorded.isEmpty)
    }

    func testAvatarIsACommandWithOneUploadThenItsWrite() async throws {
        writes.release()
        XCTAssertTrue(session.canSetAvatar)
        let setting = Task { try await session.setAvatar(attachment("me.jpg")) }
        let frame = await sent(2)
        XCTAssertEqual(frame, #"{"id":"c3","method":"command","params":{"body":{"embeds":[{"kind":"upload","title":"me.jpg"}],"text":"/avatar"}}}"#)
        await socket.deliver(["id": "c3", "result": ["embeds": [["embed_id": "e9", "kind": "upload", "write_url": "https://chat.example/write/a"]]]])
        try await setting.value
        XCTAssertEqual(writes.recorded, [Write(url: "https://chat.example/write/a", title: "me.jpg", contentType: "image/jpeg")])
        XCTAssertTrue(session.uploadProgress.isEmpty)
    }

    func testAvatarURLsFollowTheMediaPolicy() async throws {
        await socket.deliver(["method": "user", "params": ["you": ["user_id": "ada", "avatar": "https://chat.example/files/e9/s"]]])
        await eventually("avatar") { session.avatarURL(of: "ada") != nil }
        await socket.deliver(["method": "user", "params": ["new": ["user_id": "bob", "avatar": "http://elsewhere.example/b.png"]]])
        await eventually("bob kept") { session.users.user("bob") != nil }
        XCTAssertNil(session.avatarURL(of: "bob"))
    }
}
