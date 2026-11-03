@testable import ApronKit
import Foundation
import XCTest

/// Which messages notify, under which settings, mutes and silences, and what closes on reading:
/// apron-web's `notify-scopes.test.ts`, `alerts.test.ts` and `notifications.test.ts`, as Ladle has them.
final class NotifyScopeTests: XCTestCase {
    func testEachScopeSelectsItsOwnMessages() {
        let mention = ArrivalFacts(mentioned: true, inJoined: true)
        let reply = ArrivalFacts(repliesToYou: true, inJoined: true)
        let inPrivate = ArrivalFacts(inPrivate: true, inJoined: true)
        let plain = ArrivalFacts(inJoined: true)
        let unjoined = ArrivalFacts()
        let cases: [(ArrivalFacts, [NotifyScope], Bool)] = [
            (mention, [.mentions], true), (mention, [.replies], false),
            (reply, [.replies], true), (reply, [.mentions], false),
            (inPrivate, [.private], true), (inPrivate, [.mentions, .replies], false),
            (plain, [.joined], true), (plain, NotifyScope.defaults, false),
            (unjoined, [.joined], false), (unjoined, NotifyScope.allCases, false),
        ]
        for (facts, scopes, expected) in cases {
            XCTAssertEqual(facts.selected(by: scopes), expected, "\(facts) under \(scopes)")
        }
    }

    func testAMutedRoomNotifiesNothingMentionsIncluded() {
        let facts = ArrivalFacts(mentioned: true, repliesToYou: true, inPrivate: true, inJoined: true, muted: true)
        XCTAssertFalse(facts.selected(by: NotifyScope.allCases))
    }

    func testStoredScopesReadInOrderElseTheDefaults() {
        XCTAssertEqual(NotifyScope.chosen(["joined", "mentions", "everything"]), [.mentions, .joined])
        XCTAssertEqual(NotifyScope.chosen([]), [.mentions, .replies, .private])
        XCTAssertEqual(NotifyScope.chosen(nil), [.mentions, .replies, .private])
    }

    func testWakeIsTheCheckedScopesTheServerPushes() {
        XCTAssertEqual(NotifyScope.wake([.mentions, .private, .joined], offered: ["mentions", "replies", "private", "badge"]), ["mentions", "private"])
        XCTAssertNil(NotifyScope.wake([.mentions], offered: []))
        XCTAssertEqual(NotifyScope.wake([.joined], offered: ["mentions"]), [])
    }

    func testOnlyWhileOpenMarksCheckedScopesThePushLeavesOut() {
        XCTAssertEqual(NotifyScope.notes([.mentions, .joined], offered: ["mentions", "replies"], pushOn: true), [.joined: "Only while open"])
        XCTAssertEqual(NotifyScope.notes([.mentions, .joined], offered: ["mentions"], pushOn: false), [:])
        XCTAssertEqual(NotifyScope.notes([.joined], offered: [], pushOn: true), [:])
    }

    func testTitleAndBody() {
        XCTAssertEqual(Arrival.title(sender: "Bram", room: "General", namedForMembers: false), "Bram · General")
        XCTAssertEqual(Arrival.title(sender: "Bram", room: "Bram", namedForMembers: true), "Bram")
        XCTAssertEqual(Arrival.title(sender: "Bram", room: "Bram, Ada", namedForMembers: true), "Bram · Bram, Ada")
        XCTAssertEqual(Arrival.body(of: ["text": "Deploy is **done**,\n\ncheck   it", "format": "markdown"]), "Deploy is done, check it")
        XCTAssertEqual(Arrival.body(of: ["text": .string(String(repeating: "a", count: 200))]), String(repeating: "a", count: 179) + "…")
        XCTAssertEqual(Arrival.body(of: ["text": "\u{202E}abc"]), "abc")
        XCTAssertEqual(Arrival.body(of: ["text": ""]), "New message")
    }

    func testAlertIdentifiersAreThePushOnes() {
        let alert = MessageAlert(title: "t", body: "b", place: ReminderKey(server: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                                                      roomID: "general", messageID: LogID("1724803200042")!),
                                 pushID: "t65S5XBst9bSDpjJ", mention: false)
        XCTAssertEqual(alert.identifier, "apron:t65S5XBst9bSDpjJ:1724803200042")
        XCTAssertEqual(alert.group, "t65S5XBst9bSDpjJ:general")
        XCTAssertEqual(alert.userInfo, ["server": "00000000-0000-0000-0000-000000000001", "room": "general",
                                        "message": "1724803200042", "push_id": "t65S5XBst9bSDpjJ"])
        XCTAssertEqual(ReminderKey(userInfo: alert.userInfo), alert.place)
    }
}

@MainActor
final class NotificationSettingsTests: XCTestCase {
    func testKeptAcrossALaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = NotificationSettings(directory: directory, makePushID: { "pushid0000000001" })
        XCTAssertNil(settings.enabled)
        settings.setEnabled(true)
        settings.set(.joined, true, for: "a")
        settings.set(.mentions, false, for: "a")
        XCTAssertEqual(settings.pushID(of: "a"), "pushid0000000001")
        settings.setRelay(URL(string: "https://relay.example"))
        let again = NotificationSettings(directory: directory, makePushID: { "other" })
        XCTAssertEqual(again.enabled, true)
        XCTAssertEqual(again.scopes(of: "a"), [.replies, .private, .joined])
        XCTAssertEqual(again.scopes(of: "b"), [.mentions, .replies, .private])
        XCTAssertEqual(again.pushID(of: "a"), "pushid0000000001")
        XCTAssertEqual(again.account(ofPushID: "pushid0000000001"), "a")
        XCTAssertEqual(again.relay, URL(string: "https://relay.example"))
    }

    func testTheLastScopeStaysChecked() {
        let settings = NotificationSettings()
        settings.set(.replies, false, for: "a")
        settings.set(.private, false, for: "a")
        settings.set(.mentions, false, for: "a")
        XCTAssertEqual(settings.scopes(of: "a"), [.mentions])
    }

    func testAccountsAndPushIDs() {
        let server = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        XCTAssertEqual(NotificationSettings.account(server: server, userID: "ada", guest: false), "00000000-0000-0000-0000-000000000002\nada")
        XCTAssertEqual(NotificationSettings.account(server: server, userID: "guest_7", guest: true), "00000000-0000-0000-0000-000000000002\n~guest")
        let id = NotificationSettings.randomPushID()
        XCTAssertEqual(id.count, 16)
        XCTAssertTrue(id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }, id)
    }
}

@MainActor
final class MessageAlertsTests: XCTestCase {
    let server = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    var notifier: RecordingMessageNotifier!
    var alerts: MessageAlerts!

    override func setUp() async throws {
        notifier = RecordingMessageNotifier(permission: .authorized)
        alerts = MessageAlerts(settings: NotificationSettings(makePushID: { "P" }), notifier: notifier)
        await alerts.refreshPermission()
        alerts.settings.setEnabled(true)
    }

    func arrival(_ id: String, room: String = "general", _ facts: ArrivalFacts) -> Arrival {
        Arrival(server: server, account: "acct", roomID: room, messageID: LogID(id)!, sender: "Bram", room: room.capitalized,
                body: "message \(id)", facts: facts)
    }

    var posted: [String] { notifier.posted.map(\.identifier) }

    func testWhatNotifiesUnderTheDefaults() async {
        await alerts.arrived([
            arrival("1", ArrivalFacts(mentioned: true, inJoined: true)),
            arrival("2", room: "random", ArrivalFacts(inJoined: true)),
            arrival("3", room: "crew", ArrivalFacts(inPrivate: true, inJoined: true)),
            arrival("4", room: "ideas", ArrivalFacts(repliesToYou: true, inJoined: true)),
        ])
        XCTAssertEqual(posted, ["apron:P:1", "apron:P:3", "apron:P:4"])
        XCTAssertEqual(notifier.posted.first?.title, "Bram · General")
        XCTAssertEqual(notifier.posted.map(\.mention), [true, false, false])
    }

    func testJoinedCoversEveryMessage() async {
        alerts.settings.set(.joined, true, for: "acct")
        await alerts.arrived([arrival("2", room: "random", ArrivalFacts(inJoined: true))])
        XCTAssertEqual(posted, ["apron:P:2"])
    }

    func testSilencedMutedAndReadNotifyNothing() async {
        await alerts.arrived([
            arrival("1", ArrivalFacts(mentioned: true, inJoined: true, silenced: true)),
            arrival("2", room: "random", ArrivalFacts(mentioned: true, inJoined: true, muted: true)),
            arrival("3", room: "crew", ArrivalFacts(mentioned: true, inJoined: true, onScreen: true)),
        ])
        XCTAssertEqual(posted, [])
    }

    func testTheRoomOnScreenNotifiesOnceLadleIsBehind() async {
        alerts.appActive = false
        await alerts.arrived([arrival("3", room: "crew", ArrivalFacts(mentioned: true, inJoined: true, onScreen: true))])
        XCTAssertEqual(posted, ["apron:P:3"])
    }

    func testOffNotifiesNothing() async {
        alerts.settings.setEnabled(false)
        await alerts.arrived([arrival("1", ArrivalFacts(mentioned: true, inJoined: true))])
        XCTAssertEqual(posted, [])
        notifier.granted = .denied
        alerts.settings.setEnabled(true)
        await alerts.refreshPermission()
        await alerts.arrived([arrival("2", ArrivalFacts(mentioned: true, inJoined: true))])
        XCTAssertEqual(posted, [])
    }

    func testOnePerRoomItsNewestMentionElseItsNewest() async {
        await alerts.arrived([
            arrival("1", ArrivalFacts(inPrivate: true)),
            arrival("2", ArrivalFacts(mentioned: true, inPrivate: true)),
            arrival("3", ArrivalFacts(inPrivate: true)),
            arrival("4", room: "crew", ArrivalFacts(inPrivate: true)),
            arrival("5", room: "crew", ArrivalFacts(inPrivate: true)),
        ])
        XCTAssertEqual(posted, ["apron:P:2", "apron:P:5"])
    }

    func testAnOlderMessageNeverShowsUnderANewerOne() async {
        let mention = ArrivalFacts(mentioned: true, inJoined: true)
        await alerts.arrived([arrival("5", mention)])
        await alerts.arrived([arrival("4", mention)])
        await alerts.arrived([arrival("5", mention)])
        await alerts.arrived([arrival("6", mention)])
        XCTAssertEqual(posted, ["apron:P:5", "apron:P:6"])
    }

    func testReadingClosesTheRoomsNotificationsUpToThere() async {
        await alerts.arrived([arrival("5", ArrivalFacts(mentioned: true))])
        await alerts.read("general", through: LogID("7")!, account: "acct")
        await alerts.read("general", through: LogID("8")!, account: "no push_id yet")
        XCTAssertEqual(notifier.closed.map(\.group), ["P:general"])
        XCTAssertEqual(notifier.closed.map(\.through), [LogID("7")!])
    }

    func testTheBadgeIsTheUnreadCountWhileOn() async {
        await alerts.setBadge(3)
        await alerts.setBadge(3)
        await alerts.setBadge(0)
        await alerts.turnOff()
        await alerts.setBadge(5)
        XCTAssertEqual(notifier.badges, [3, 0])
    }

    func testTheFirstMentionYoudHearOffersNotifications() async {
        let fresh = RecordingMessageNotifier()
        let alerts = MessageAlerts(settings: NotificationSettings(), notifier: fresh)
        await alerts.arrived([arrival("1", ArrivalFacts(mentioned: true, muted: true)), arrival("2", ArrivalFacts(inJoined: true))])
        XCTAssertNil(alerts.offer)
        await alerts.arrived([arrival("3", room: "crew", ArrivalFacts(mentioned: true, inJoined: true))])
        XCTAssertEqual(alerts.offer, NotifyOffer(from: "Bram", room: "Crew"))
        XCTAssertEqual(fresh.posted, [])
        await alerts.turnOn()
        XCTAssertNil(alerts.offer)
        XCTAssertTrue(alerts.isOn)
        XCTAssertEqual(alerts.settings.enabled, true)
    }

    func testNotNowIsAChoiceSoTheOfferDoesNotReturn() async {
        let alerts = MessageAlerts(settings: NotificationSettings(), notifier: RecordingMessageNotifier())
        await alerts.arrived([arrival("1", ArrivalFacts(mentioned: true))])
        alerts.decline()
        await alerts.arrived([arrival("2", ArrivalFacts(mentioned: true))])
        alerts.offerAtSignIn()
        XCTAssertNil(alerts.offer)
        XCTAssertEqual(alerts.settings.enabled, false)
    }

    func testNoOfferOnceIOSRefusesOrWhileSilenced() async {
        let refused = MessageAlerts(settings: NotificationSettings(), notifier: RecordingMessageNotifier(permission: .denied))
        await refused.refreshPermission()
        await refused.arrived([arrival("1", ArrivalFacts(mentioned: true))])
        XCTAssertNil(refused.offer)
        let paused = MessageAlerts(settings: NotificationSettings(), notifier: RecordingMessageNotifier())
        await paused.arrived([arrival("1", ArrivalFacts(mentioned: true, silenced: true))])
        XCTAssertNil(paused.offer)
        paused.offerAtSignIn()
        XCTAssertEqual(paused.offer, NotifyOffer())
    }

    func testTestNotification() async {
        let sent = await alerts.sendTest()
        XCTAssertEqual(sent, .sent)
        notifier.granted = .denied
        await alerts.refreshPermission()
        let refused = await alerts.sendTest()
        XCTAssertEqual(refused, .denied)
        XCTAssertEqual(notifier.tests, 1)
    }
}

/// What a session hands over from its connection: the messages that may notify, with what it knows of each.
final class SessionArrivalsTests: ScriptedSessionCase {
    var arrived: [Arrival] = []
    var read: [String] = []

    func signInWithRooms(_ transport: FakeTransport) async throws {
        session.start()
        await eventually("signed out") { session.status == .signedOut }
        session.onArrivals = { [weak self] in self?.arrived += $0 }
        session.onRead = { [weak self] account, room, message in self?.read.append("\(account.split(separator: "\n").last ?? "") \(room) \(message.text)") }
        let signIn = Task { try await session.signIn(.token("t")) }
        _ = await sent(transport, count: 2)
        await transport.deliver(["id": "c1", "result": ["you": ["user_id": "ada", "name": "Ada"]]])
        await transport.deliver(["id": "c2", "result": ["joined": [
            ["room_id": "general", "log_id": "100", "title": "General", "latest_log_id": "100", "history_log_id": "100"],
            ["room_id": "ideas", "log_id": "101", "title": "Ideas", "parent_room_id": "general", "latest_log_id": "101", "history_log_id": "101"],
            ["room_id": "crew", "log_id": "102", "private": true, "latest_log_id": "102", "history_log_id": "102",
             "members": [["user_id": "ada", "name": "Ada"], ["user_id": "bram", "name": "Bram"]]],
            ["room_id": "random", "log_id": "103", "title": "Random", "latest_log_id": "103", "history_log_id": "103"],
        ]]])
        _ = try await signIn.value
    }

    func message(_ id: String, log: String? = nil, room: String, from: String = "bram", text: String = "hi",
                 mentions: [String] = [], replyTo: String? = nil) -> JSONValue {
        var params: [String: JSONValue] = ["message_id": .string(id), "log_id": .string(log ?? id), "room_id": .string(room),
                                           "from": ["user_id": .string(from), "name": .string(from.capitalized)],
                                           "body": ["text": .string(text), "mentions": .array(mentions.map(JSONValue.string))]]
        if let replyTo { params["reply_to"] = ["message_id": .string(replyTo)] }
        return ["method": "message", "params": .object(params)]
    }

    func testEachArrivalCarriesWhatTheSessionKnows() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity", "status"])
        try await signInWithRooms(socket)
        session.show("random", true)
        await socket.deliver(message("200", room: "general", from: "ada", text: "mine"))
        await socket.deliver(message("201", room: "general", text: "@ada look", mentions: ["ada"]))
        await socket.deliver(message("202", room: "ideas", text: "re", replyTo: "200"))
        await socket.deliver(message("203", room: "crew", text: "psst"))
        await socket.deliver(message("204", room: "random", text: "on screen"))
        await socket.deliver(status(["room_id": "general", "mute": true]))
        await socket.deliver(message("205", room: "ideas", text: "muted with its room"))
        await eventually("five arrivals") { arrived.count == 5 }
        XCTAssertEqual(arrived.map(\.messageID.text), ["201", "202", "203", "204", "205"])
        XCTAssertEqual(arrived.map(\.facts), [
            ArrivalFacts(mentioned: true, inJoined: true),
            ArrivalFacts(repliesToYou: true, inJoined: true),
            ArrivalFacts(inPrivate: true, inJoined: true),
            ArrivalFacts(inJoined: true, onScreen: true),
            ArrivalFacts(inJoined: true, muted: true),
        ])
        XCTAssertEqual(arrived.map(\.title), ["Bram · General", "Bram · Ideas", "Bram", "Bram · Random", "Bram · Ideas"])
        XCTAssertEqual(arrived.first?.account, "00000000-0000-0000-0000-000000000009\nada")
    }

    func testAnEditNotifiesOnlyWhenItAddsYou() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity", "status"])
        try await signInWithRooms(socket)
        await socket.deliver(message("300", room: "general", text: "hello"))
        await socket.deliver(message("300", log: "301", room: "general", text: "hello again"))
        await socket.deliver(message("300", log: "302", room: "general", text: "hello @ada", mentions: ["ada"]))
        await socket.deliver(message("300", log: "303", room: "general", text: "hello @ada!", mentions: ["ada"]))
        await socket.deliver(message("304", room: "general", text: "after"))
        await eventually("three arrivals") { arrived.count == 3 }
        XCTAssertEqual(arrived.map(\.messageID.text), ["300", "300", "304"])
        XCTAssertEqual(arrived.map(\.facts.mentioned), [false, true, false])
    }

    func testDoNotDisturbAndAPauseSilence() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity", "status"])
        try await signInWithRooms(socket)
        await socket.deliver(["method": "user", "params": ["you": ["user_id": "ada", "status": "dnd"]]])
        await socket.deliver(message("400", room: "general", mentions: ["ada"]))
        await socket.deliver(["method": "user", "params": ["you": ["user_id": "ada", "status": ""]]])
        await socket.deliver(status(["mute": true]))
        await socket.deliver(message("401", room: "general", mentions: ["ada"]))
        await socket.deliver(status(["mute": false]))
        await socket.deliver(message("402", room: "general", mentions: ["ada"]))
        await eventually("three arrivals") { arrived.count == 3 }
        XCTAssertEqual(arrived.map(\.facts.silenced), [true, true, false])
    }

    func testReadingHereOrOnAnotherDeviceIsReported() async throws {
        let socket = queueTransport(capabilities: ["history", "rooms", "activity", "status"])
        try await signInWithRooms(socket)
        await socket.deliver(message("500", room: "general"))
        await socket.deliver(["method": "activity", "params": ["room_id": "general", "from": ["user_id": "ada"], "read_message_id": "500"]])
        await socket.deliver(["method": "activity", "params": ["room_id": "general", "from": ["user_id": "bram"], "read_message_id": "500"]])
        await eventually("one read") { read.count == 1 }
        await session.markRead("crew", through: LogID("600")!)
        XCTAssertEqual(read, ["ada general 500", "ada crew 600"])
    }
}
