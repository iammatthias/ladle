@testable import ApronKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Attachments and avatars against the real Rust server (§4.8.3, §4.8.4, §4.8.6): the message,
/// its write over HTTP, the completed snapshot, and the hosted bytes.
@MainActor
final class UploadIntegrationTests: XCTestCase {
    private var servers: [Aprond] = []
    private var sessions: [ServerSession] = []
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ladle-uploads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for session in sessions { await session.stop() }
        for server in servers { server.stop() }
        try? FileManager.default.removeItem(at: directory)
    }

    private func signedInGuest(_ arguments: [String] = []) async throws -> ServerSession {
        let server = try await Aprond.start(arguments)
        servers.append(server)
        let environment = ServerSession.Environment(makeTransport: { WebSocketTransport(url: $0.url, origin: $0.origin) })
        let session = ServerSession(record: ServerRecord(url: server.url), tokens: InMemoryTokenStore(), environment: environment)
        sessions.append(session)
        session.start()
        try await waitFor("connected") { session.status == .signedOut }
        try await session.signIn(.guest(name: "Ada"))
        return session
    }

    private func png(width: Int, height: Int) throws -> URL {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.35, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let url = directory.appending(path: "before.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    func testAnImageRoundTripsFromSendToTheHostedBytes() async throws {
        let session = try await signedInGuest()
        XCTAssertTrue(session.canAttach)
        try await session.open("general")
        let attachment = try AttachmentPreparer.prepare(try png(width: 320, height: 180), title: "before.png",
                                                        limits: session.mediaLimits?.upload, into: directory)
        XCTAssertEqual(attachment.contentType, "image/png")

        let posted = try await session.send("Before the fix:", in: "general", attachments: [attachment])
        let messageID = try XCTUnwrap(posted)
        try await waitFor("the completed embed", timeout: .seconds(10)) {
            session.store.message(messageID)?.embedList.first?.url != nil
        }
        let embed = try XCTUnwrap(session.store.message(messageID)?.embedList.first)
        XCTAssertEqual(embed.kind, "upload")
        XCTAssertEqual(embed.title, "before.png")
        XCTAssertNotNil(embed.embedID)
        guard case .image(let media) = embed.upload else { return XCTFail("expected an image, got \(String(describing: embed.upload))") }
        XCTAssertEqual(media.type, "image/png")
        XCTAssertEqual([media.width, media.height], [320, 180])
        let url = try XCTUnwrap(embed.url)
        XCTAssertTrue(session.mediaPolicy.allowsMedia(url), "\(url) is the server's own origin")
        XCTAssertTrue(session.mediaPolicy.allowsMedia(media.url))
        try await waitFor("the write finished") { session.uploadProgress.isEmpty }
        XCTAssertTrue(session.outbox.isEmpty)

        let (bytes, response) = try await fetch(url)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(bytes, try Data(contentsOf: attachment.fileURL), "the hosted file is the one sent")
        print("round trip: message \(messageID.text), embed \(embed.embedID ?? "?"), \(url.absoluteString), \(bytes.count) bytes, og.image \(media.width ?? 0)x\(media.height ?? 0)")
    }

    func testAFileOverTheServersLimitIsDroppedAndComesBackAsNotSent() async throws {
        let session = try await signedInGuest(["--upload.max-mb", "1"])
        try await session.open("general")
        let source = directory.appending(path: "big.bin")
        try Data(repeating: 1, count: 1_500_000).write(to: source)
        let attachment = try AttachmentPreparer.prepare(source, title: "big.bin", contentType: "application/octet-stream", limits: nil, into: directory)

        session.post("too big", in: "general", attachments: [attachment])
        try await waitFor("not sent", timeout: .seconds(20)) { session.outbox.first.map { $0.state != .sending } ?? false }
        let item = try XCTUnwrap(session.outbox.first)
        XCTAssertTrue([.failed("The file is larger than this server accepts."), .failed("The upload didn't reach the server.")].contains(item.state),
                      "413, or the server closed before reading the body: \(item.state)")
        XCTAssertEqual(item.attachments.map(\.title), ["big.bin"])
        print("over the limit: \(item.state)")
        let message = try XCTUnwrap(session.timeline("general").last { $0.body?["text"] == "too big" })
        try await waitFor("the embed dropped", timeout: .seconds(10)) { session.store.message(message.messageID)?.embedList.isEmpty == true }
    }

    func testAnAvatarUploadSetsTheAvatarOnYou() async throws {
        let session = try await signedInGuest()
        XCTAssertTrue(session.canSetAvatar)
        let image = try AttachmentPreparer.prepare(try png(width: 64, height: 64), title: "me.png", limits: nil, into: directory)
        try await session.setAvatar(image)
        let me = try XCTUnwrap(session.you?.userID)
        try await waitFor("avatar set", timeout: .seconds(10)) { session.avatarURL(of: me) != nil }
        let (bytes, response) = try await fetch(try XCTUnwrap(session.avatarURL(of: me)))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(bytes, try Data(contentsOf: image.fileURL))
    }
}
