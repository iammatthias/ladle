import XCTest
@testable import ApronKit

@MainActor
final class PreviewFixturesTests: XCTestCase {
    func testTheSeedHoldsEveryStateTheScreenshotsShow() async throws {
        let store = await PreviewFixtures.makeStore()
        XCTAssertEqual(store.records.map(\.label), ["Home", "demo.apron.example"])
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let demo = try XCTUnwrap(store.session(for: PreviewFixtures.demoID))
        XCTAssertEqual(home.status, .signedIn)
        XCTAssertEqual(demo.status, .signedIn)

        XCTAssertEqual(home.publicRoomTree.map { home.title(of: $0.roomID) }, ["design", "general", "kitchen", "markdown", "random", "remote"])
        XCTAssertEqual(home.privateRoomTree.map { home.title(of: $0.roomID) }, ["Ada Okafor", "Bram, Chiara", "Launch plan", "ops"])
        XCTAssertEqual(home.publicRoomTree.map { $0.threadIDs.map(home.title(of:)) }, [["Icon sketches"], ["Release 0.2", "Load test", "Origin check", "Docs", "Passkeys", "Benchmarks", "Untitled", "Hiring", "Archive 2025", "2024 offsite", "Icons v1"], [], [], [], []],
                       "most recently active first, those not joined among them")
        for _ in 0 ..< 100 where home.typingNames(in: PreviewFixtures.typingRoomID).count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(home.typingNames(in: PreviewFixtures.typingRoomID), ["Ada Okafor", "Bram"])
        XCTAssertEqual(home.typingNames(in: PreviewFixtures.busyRoomID), [])
        XCTAssertEqual(home.mute(of: PreviewFixtures.mutedRoomID), .own(.untilChanged))
        XCTAssertEqual(home.mute(of: PreviewFixtures.linkCardRoomID), .withRoom(PreviewFixtures.mutedRoomID, .untilChanged))
        XCTAssertNil(home.mute(of: PreviewFixtures.busyRoomID))
        try await home.setPause(.untilChanged)
        for _ in 0 ..< 100 where home.pause == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(home.profileLine, "Paused until you resume", "the preview server echoes a pause")
        try await home.setPause(nil)
        for _ in 0 ..< 100 where home.pause != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(home.pause)

        let blocks = home.timeline(PreviewFixtures.markdownRoomID).flatMap { MessageText.blocks($0.body) }
        XCTAssertEqual(Set(blocks.map { block -> String in
            switch block {
            case .paragraph: "paragraph"
            case .heading: "heading"
            case .quote: "quote"
            case .list: "list"
            case .code: "code"
            case .rule: "rule"
            case .table: "table"
            case .image: "image"
            }
        }), ["paragraph", "heading", "quote", "list", "code", "rule", "table"], "every block but an image, which the remote room has")
        XCTAssertEqual(blocks.compactMap { block -> String? in
            if case .code(let language, let text) = block { "\(language ?? "none"):\(CodeHighlighter.highlighted(text, fence: language) != nil)" } else { nil }
        }, ["swift:true", "python:true", "diff:true", "json:true", "brainfuck:false"], "highlighted blocks, and one in a language nobody highlights")
        let gate = home.mediaGate
        let images = home.timeline(PreviewFixtures.elsewhereRoomID).flatMap { MessageText.blocks($0.body) }.compactMap { block -> MediaDecision? in
            if case .image(let image) = block { gate.decide(image.url) } else { nil }
        }
        XCTAssertEqual(images.compactMap { if case .ask(let ask) = $0 { ask.host } else { nil } }, ["shazow.net", "evildomain.example.com"])
        let card = try XCTUnwrap(home.timeline(PreviewFixtures.elsewhereRoomID).first?.embedList.first?.og)
        XCTAssertEqual(card.ask(gate: gate)?.kind, .video, "the video waits though the image is the server's own")

        let kitchen = home.timeline(PreviewFixtures.emojiRoomID)
        XCTAssertEqual(home.emojiCatalog?.offered.map(\.key), [":apron:", ":shipit:", ":smilingpan:", ":partyparrot:"], "the hidden one is not offered")
        XCTAssertEqual(home.store.reactions(on: kitchen[0].messageID)?.map(\.emoji), [":apron:", ":partyparrot:", ":retired:", "👍"],
                       "one key the catalog lacks, for the placeholder")
        XCTAssertEqual(TextDirection(of: kitchen[1].body?["text"]?.stringValue ?? ""), .rightToLeft)
        XCTAssertEqual(home.unreadCount(in: PreviewFixtures.emojiRoomID), 0)

        let general = home.timeline(PreviewFixtures.busyRoomID)
        XCTAssertEqual(general.count, 13)
        let deleted = home.store.messages(in: PreviewFixtures.busyRoomID).filter(\.isTombstone)
        XCTAssertEqual(deleted.count, 1, "one deleted message, left out of the timeline")
        XCTAssertEqual(general.filter { $0.logID != $0.messageID }.count, 1, "one edit")
        XCTAssertEqual(general.compactMap(\.replyTo).count, 4)
        XCTAssertEqual(general.compactMap(\.replyTo).filter { home.store.message($0)?.isTombstone == true }, deleted.map(\.messageID),
                       "one reply quotes the deleted message")
        let notes = try XCTUnwrap(general.first { $0.body?["text"]?.stringValue?.hasPrefix("Notes from the sync") == true })
        XCTAssertEqual(home.store.reactions(on: notes.messageID)?.map(\.emoji), ["🎉", "👍"], "code point order")
        XCTAssertEqual(home.store.reactions(on: notes.messageID)?.last?.userIDs, ["bram", "chiara", "sam"])
        XCTAssertNotNil(home.store.message(PreviewFixtures.replyTargetID))

        XCTAssertEqual(home.unreadCount(in: "general"), 3, "minutes 15, 16 and 20: Sam's own at 14 says he read through it")
        XCTAssertEqual(general.filter { $0.body?["mentions"]?.arrayValue?.contains("sam") == true }.count, 1, "one mention of you")
        XCTAssertEqual(general.compactMap(\.prevRoomID), ["ops"], "one moved message")
        XCTAssertEqual(general.compactMap { $0.body?["embeds"]?.arrayValue?.first?["kind"]?.stringValue }, ["link", "poll"])
        XCTAssertEqual(home.store.room("ops")?.isPrivate, true)
        XCTAssertEqual(home.notices.map(\.roomID), ["general", "ops"], "the release freeze, and /invite-device add's sign-in link")
        XCTAssertEqual(home.store.room(PreviewFixtures.releaseThreadID)?.description?.stringValue, "Ship Friday, then freeze")
        XCTAssertEqual(home.unreadCount(in: "random"), 0, "Sam's pending upload is the newest message")
        let uploads = home.timeline(PreviewFixtures.mediaRoomID).flatMap(\.embedList).compactMap(\.upload)
        XCTAssertEqual(uploads.map { upload -> String in
            switch upload {
            case .pending: "pending"
            case .image(let media): "image \(media.width ?? 0)x\(media.height ?? 0)"
            case .video: "video"
            case .audio: "audio"
            case .file: "file"
            }
        }, ["image 1200x1600", "image 1600x1200", "image 1600x1200", "video", "file", "audio", "pending"])
        let mine = try XCTUnwrap(home.timeline(PreviewFixtures.mediaRoomID).first { $0.messageID == PreviewFixtures.editedUploadsID })
        XCTAssertEqual([MessageMenu(mine, in: home).editable, mine.replyTo != nil], [true, true], "Sam's two photos, a reply, for the editor shot")
        XCTAssertTrue(home.canAttach)
        XCTAssertEqual(home.timeline(PreviewFixtures.releaseThreadID).count, 4, "Release 0.2")
        XCTAssertEqual(home.unreadCount(in: PreviewFixtures.releaseThreadID), 2)
        XCTAssertEqual(home.unreadCount(in: "design"), 0)
        let players = home.timeline(PreviewFixtures.linkRoomID).flatMap(\.embedList).compactMap { $0.og?.player(gate: home.mediaGate) }
        XCTAssertEqual(players.map { player -> String in
            switch player {
            case .video(_, let poster): poster == nil ? "video" : "video with poster"
            case .audio(_, let cover): cover == nil ? "audio" : "audio with cover"
            }
        }, ["video with poster", "audio with cover"])
        let linking = home.timeline(PreviewFixtures.linkCardRoomID).suffix(3)
        XCTAssertEqual(linking.map { home.placeCards(in: $0).map(\.roomTitle) }, [["general"], ["Release 0.2", "ops"], ["general", "design", "Release 0.2"]],
                       "a message, a thread, a private room; the chips' places, three at most")
        XCTAssertEqual(linking.map { message in
            message.embedList.filter { PlaceCard.previews($0, in: home.placeCards(in: message), from: home.record.url) }.count
        }, [1, 0, 0], "a sender's preview the card hides")
        let chips = MessageBlock.flattened(MessageRowModel(try XCTUnwrap(linking.last), in: home).blocks)
        XCTAssertEqual(chips.runs.compactMap { run in run[LinkChipKey.self].map { _ in String(chips[run.range].characters) } ?? run[MentionKey.self].map { _ in String(chips[run.range].characters) } },
                       ["Message", " in #\u{2068}general\u{2069}", "\u{2068}design\u{2069}", "\u{2068}Release 0.2\u{2069}", " in #\u{2068}general\u{2069}",
                        "@\u{2068}Ada Okafor\u{2069}", "demo.apron.example", " · Room"], "the round-up's link chips")
        XCTAssertEqual(demo.unreadCount(in: "lobby"), 3)
        XCTAssertEqual(demo.memberListNote("lobby"), "Showing 3 of 1204: the most recently active", "the lobby's listing is truncated")
        XCTAssertEqual(demo.profile(of: UserObject(["user_id": "mo", "name": "Mo"])!, in: "lobby").membership,
                       "Not among the recently active members of lobby")
        XCTAssertNil(home.memberListNote(PreviewFixtures.busyRoomID))
        XCTAssertFalse(demo.mayWrite, "a guest the demo lets only read")
        XCTAssertEqual(demo.firstRoom, "help")
        XCTAssertEqual(demo.notices(in: "help").map { $0.body?["text"]?.stringValue }, [PreviewFixtures.demoWelcome],
                       "the welcome before auth, kept for a guest given no token, in the first room")
        XCTAssertEqual(demo.notices(in: "lobby"), [])
        XCTAssertFalse(home.notices.contains(where: \.welcome))
        XCTAssertEqual(demo.serverName, "Apron Demo", "named by its title")
        XCTAssertEqual(demo.serverAvatarURL?.absoluteString, PreviewFixtures.demoAvatarURL)
        XCTAssertTrue(home.mayWrite)
        XCTAssertEqual(UploadOffer(demo.mediaLimits?.upload).summary, "This server takes images and audio only.")
        XCTAssertEqual(home.users.user("chiara")?["status"]?.stringValue, "dnd")
        XCTAssertEqual(["ada", "chiara", "dev", "eunji", "sam"].map { home.roles(of: UserObject(["user_id": .string($0)])!) },
                       [["admin"], ["mod", "announce"], ["bot"], ["announce"], []], "role badges")
        XCTAssertEqual(home.roles(of: UserObject(["user_id": "zed", "roles": ["bot"]])!), ["bot"], "an unknown user's roles come from the object given")
    }

    func testTheComposerShotsLinksBuildTheCardTheSentMessageShows() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        await home.linkPreviews.prefetch(PreviewFixtures.linkPreviewDraft)
        let built = home.linkPreviews.embeds(in: PreviewFixtures.linkPreviewDraft)
        XCTAssertEqual(built.map(\.og?.title), ["Bowl-only app icon", "Ladle (spoon)"])
        XCTAssertEqual(built.map(\.og?.siteName), ["GitHub · example/ladle", "Wikipedia"])
        let sent = home.timeline(PreviewFixtures.linkCardRoomID).flatMap(\.embedList).first { $0.url?.host() == "github.com" }
        XCTAssertEqual(sent?.og, built.first?.og, "the sent message carries the card the composer built")
    }

    func testThePreviewServerRefusesAKickForTheFailedCommandShot() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let draft = ComposerDraft(field: DraftField(text: "/kick @Dev ", mentions: ["dev": "Dev"]))
        do {
            try await home.submit(draft, in: "ops")
            XCTFail("kicked")
        } catch let failure as CommandFailure {
            XCTAssertEqual(failure.reason, "Only an admin, the room's creator, or a bot's owner, can remove someone else")
            XCTAssertEqual(failure.draft, draft)
        }
        XCTAssertEqual(home.notices.filter { $0.roomID == "ops" }.compactMap { $0.body?["text"]?.stringValue }.last,
                       "Only an admin, the room's creator, or a bot's owner, can remove someone else")
    }

    func testBrowseRoomsListsTheGardenAndBookClubWithCountsAndTheGardenReadsBeforeJoining() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let listed = try await home.listUnjoinedRooms()
        XCTAssertEqual(listed, [PreviewFixtures.gardenRoomID, "books"])
        XCTAssertEqual(listed.map { home.memberTotal($0) }, [3, 12])
        XCTAssertEqual(listed.map { home.roomDescription($0) }, ["Seeds, soil and the allotment rota", "This month: *The Dispossessed*"])
        try await home.open(PreviewFixtures.gardenRoomID)
        XCTAssertEqual(home.timeline(PreviewFixtures.gardenRoomID).map(\.plainText),
                       ["The tomatoes made it through the frost.", "Who has the rota this week?", "Me. Watering Tuesday and Friday."])
        XCTAssertFalse(home.joinedRoomIDs.contains(PreviewFixtures.gardenRoomID))
        XCTAssertFalse(home.roomTree.contains { $0.roomID == PreviewFixtures.gardenRoomID }, "read, not listed with your rooms")
        XCTAssertEqual(home.readingNode(open: PreviewFixtures.gardenRoomID), RoomNode(roomID: PreviewFixtures.gardenRoomID, threadIDs: []),
                       "but shown open under Other Rooms while it is the one read")
        XCTAssertEqual(home.threadNode(of: PreviewFixtures.gardenRoomID)?.roomID, PreviewFixtures.gardenRoomID)
        XCTAssertEqual([home.readingNode(open: "general"), home.readingNode(open: PreviewFixtures.releaseThreadID), home.readingNode(open: nil)],
                       [nil, nil, nil], "a joined room, a thread of one, or nothing open")
    }
}
