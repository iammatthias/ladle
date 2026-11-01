import XCTest
@testable import ApronKit

/// A session reading live text for the rows that show it, against `PreviewFixtures`' Load test
/// thread: a live terminal and a live append, served by its scripted reader.
@MainActor
final class LiveTextSessionTests: XCTestCase {
    private func home() async throws -> ServerSession {
        let store = await PreviewFixtures.makeStore()
        return try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
    }

    private func message(_ id: String, in session: ServerSession) throws -> MessageSnapshot {
        try XCTUnwrap(session.store.message(LogID(id)!))
    }

    func testAnAppendsTextFollowsTheBodyWhileItIsWritten() async throws {
        let session = try await home()
        let snapshot = try message(PreviewFixtures.liveAppendMessageID, in: session)
        let before = MessageRowModel(snapshot, in: session)
        XCTAssertEqual(String(MessageBlock.flattened(before.blocks).characters), "Asked the planner what to do if it fails:", "nothing read before a row follows it")
        let live = try XCTUnwrap(before.liveAppend)
        let following = Task { await session.follow(live) }
        await eventually("the reply arrived") { live.text.hasSuffix("kubectl rollout") }
        let row = MessageRowModel(snapshot, in: session)
        XCTAssertTrue(row.isWriting)
        XCTAssertTrue(live.text.hasPrefix("Here is the plan"), "the form feed cleared the placeholder")
        XCTAssertTrue(live.text.contains("so every deploy since then failed."), "the backspaces corrected the typo")
        let shown = String(MessageBlock.flattened(row.blocks).characters)
        XCTAssertTrue(shown.hasPrefix("Asked the planner what to do if it fails:\nHere is the plan for the rollback, step by step:"))
        guard case .code(let code)? = row.blocks.last else { return XCTFail("the open fence shows as a code block: \(row.blocks)") }
        XCTAssertEqual(code.text, "./migrate down 0042\nkubectl rollout")
        XCTAssertEqual(row.embeds.count, 0, "no card for an append")
        following.cancel()
        await eventually("the read stops with its last follower") { live.reading == nil }
        XCTAssertTrue(session.liveText(of: snapshot.embedList[0]) === live, "kept by url for a row that scrolls back")
    }

    func testATerminalIsReadOnceForTheMessageAndTheViewer() async throws {
        let session = try await home()
        let snapshot = try message(PreviewFixtures.liveTerminalMessageID, in: session)
        let embed = try XCTUnwrap(snapshot.embedList.first)
        let live = try XCTUnwrap(session.liveText(of: embed))
        XCTAssertEqual(live.kind, .terminal)
        let first = Task { await session.follow(live) }
        let second = Task { await session.follow(live) }
        await eventually("the run arrived") { live.screen.plainText.contains("ramping to 500") }
        XCTAssertEqual(live.phase, .live)
        XCTAssertTrue(live.screen.plainText.hasPrefix("$ make ramp"))
        live.openViewer()
        XCTAssertEqual(live.viewerScreen?.plainText, live.screen.plainText, "the viewer replays the text since the response began")
        live.closeViewer()
        first.cancel()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(live.reading, "one follower is left")
        second.cancel()
        await eventually("the read stops") { live.reading == nil }
    }

    func testLiveTextWaitsForItsWriterUntilASnapshotAddsItsURL() async throws {
        let session = try await home()
        let terminal = try XCTUnwrap(message(PreviewFixtures.waitingTerminalMessageID, in: session).embedList.first)
        XCTAssertTrue(terminal.isWaitingForWriter)
        XCTAssertNil(session.liveText(of: terminal), "nothing to read before the write starts")
        let waiting = try message(PreviewFixtures.waitingAppendMessageID, in: session)
        let before = MessageRowModel(waiting, in: session)
        XCTAssertEqual([before.isWaiting, before.isWriting], [true, false])
        XCTAssertEqual(before.liveLine, "Waiting to stream…")
        XCTAssertNil(before.liveAppend)
        XCTAssertEqual(String(MessageBlock.flattened(before.blocks).characters), "Drafting the ramp report:")

        var started = waiting
        started.body = ["text": "Drafting the ramp report:\n\n", "embeds": [["embed_id": "embed_a3", "kind": "append", "url": .string(PreviewFixtures.liveAppendURL.absoluteString)]]]
        let after = MessageRowModel(started, in: session)
        XCTAssertFalse(after.isWaiting)
        let live = try XCTUnwrap(after.liveAppend, "the snapshot that adds url starts the read")
        let following = Task { await session.follow(live) }
        await eventually("the reply arrived") { live.text.hasSuffix("kubectl rollout") }
        XCTAssertEqual(MessageRowModel(started, in: session).liveLine, "Writing…")
        following.cancel()
    }

    func testAURLElsewhereIsUnavailableNotWaiting() throws {
        let elsewhere = try XCTUnwrap(Embed(["embed_id": "e", "kind": "terminal", "url": "https://elsewhere.example/live/x"]))
        XCTAssertFalse(elsewhere.isWaitingForWriter)
        let finished = try XCTUnwrap(Embed(["embed_id": "e", "kind": "terminal", "output": "ok"]))
        XCTAssertFalse(finished.isWaitingForWriter, "a terminal with output is finished")
    }

    func testATextThatEndedIsNotReadAgain() async throws {
        let session = try await home()
        let gone = try XCTUnwrap(Embed(["embed_id": "e", "kind": "terminal", "url": "https://home.example/live/gone"]))
        let live = try XCTUnwrap(session.liveText(of: gone))
        let first = Task { await session.follow(live) }
        await eventually("the read ended") { live.phase == .ended }
        first.cancel()
        await eventually("the first follower left") { live.watchers == 0 }
        let again = Task { await session.follow(live) }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(live.reading, "no grace period: the url's end is final, and a new view reads nothing")
        again.cancel()
    }

    func testLiveTextLoadsOnlyFromTheChatServersOrigin() async throws {
        let session = try await home()
        let elsewhere = try XCTUnwrap(Embed(["embed_id": "e", "kind": "terminal", "url": "https://elsewhere.example/live/x"]))
        XCTAssertNil(session.liveText(of: elsewhere))
        let finished = try XCTUnwrap(Embed(["embed_id": "e", "kind": "terminal", "output": "ok", "url": "https://home.example/live/x"]))
        XCTAssertNil(session.liveText(of: finished), "a terminal with output is finished")
        let own = try XCTUnwrap(Embed(["embed_id": "e", "kind": "append", "url": "https://home.example/live/y"]))
        XCTAssertNotNil(session.liveText(of: own))
    }

    func testARefusedReadEndsAndKeepsWhatShows() async throws {
        let session = try await home()
        let gone = try XCTUnwrap(Embed(["embed_id": "e", "kind": "terminal", "url": "https://home.example/live/gone"]))
        let live = try XCTUnwrap(session.liveText(of: gone))
        let following = Task { await session.follow(live) }
        await eventually("the 404 ended it") { live.phase == .ended }
        XCTAssertFalse(live.isLive)
        following.cancel()
    }

    func testReadReceiptsInTheFixturesPrivateRooms() async throws {
        let session = try await home()
        XCTAssertTrue(session.offersReadReceipts)
        let direct = session.receipts(in: PreviewFixtures.directRoomID, shown: session.timeline(PreviewFixtures.directRoomID))
        XCTAssertEqual(direct.mapValues { $0.map(\.name) }, [LogID(PreviewFixtures.message(31))!: ["Ada Okafor"]])
        let crew = session.receipts(in: PreviewFixtures.groupRoomID, shown: session.timeline(PreviewFixtures.groupRoomID))
        XCTAssertEqual(crew.mapValues { $0.map(\.name) }, [LogID(PreviewFixtures.message(34))!: ["Bram", "Chiara"]])
    }
}
