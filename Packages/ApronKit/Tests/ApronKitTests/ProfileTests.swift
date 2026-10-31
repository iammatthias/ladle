import Foundation
import Synchronization
import XCTest
@testable import ApronKit

/// Your own profile and status: `me` (§3.3.2, §4.5), the You sheet's form, and the status picker.
@MainActor
final class ProfileTests: XCTestCase {
    var session: ServerSession!
    var socket: FakeTransport!
    var accounts: [ServerRecord.Account?] = []

    private func signIn(capabilities: [String], statuses: [String]? = nil,
                        you: JSONValue = ["user_id": "ada", "name": "Ada", "status": "online"]) async throws {
        let counter = Mutex(0)
        let socket = FakeTransport()
        self.socket = socket
        let environment = ServerSession.Environment(
            makeTransport: { _ in socket },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) },
            jitter: { 1 },
            makeRequestID: { counter.withLock { $0 += 1; return "c\($0)" } }
        )
        session = ServerSession(record: ServerRecord(url: URL(string: "wss://chat.example/ws")!), tokens: InMemoryTokenStore(), environment: environment)
        session.onRecordChange = { [weak self] in self?.accounts.append($0.account) }
        session.start()
        var greeting: [String: JSONValue] = ["apron": 9, "auth": ["token"], "capabilities": .array(capabilities.map(JSONValue.string))]
        if let statuses { greeting["status"] = .array(statuses.map(JSONValue.string)) }
        await socket.deliver(["method": "server", "params": .object(greeting)])
        await eventually("signed out") { session.status == .signedOut }
        let signIn = Task { try await session.signIn(.token("t1")) }
        await eventually("auth and room_list sent") { await socket.sentLog.count == 2 }
        await socket.deliver(["id": "c1", "result": ["you": you]])
        await socket.deliver(["id": "c2", "result": ["joined": [["room_id": "general"]]]])
        _ = try await signIn.value
    }

    override func tearDown() async throws {
        await session?.stop()
    }

    private func sent(_ index: Int) async -> String {
        await eventually("frame \(index)") { await socket.sentLog.count > index }
        return await socket.sentLog[index]
    }

    // MARK: Bio

    func testABioIsCleanedAsTheWebCleansIt() {
        XCTAssertEqual(Bio.clean("  Cooks\tsoup.  \r\nevil\u{202E}gnp.exe\u{0007}\n\n\n\nBye  "), "Cooks soup.\nevilgnp.exe\n\nBye")
        XCTAssertEqual(Bio.clean("a\u{2028}b\rc\u{2066}d\u{2069}"), "a\nb\ncd")
        XCTAssertEqual(Bio.clean(String(repeating: "🦆", count: 260)), String(repeating: "🦆", count: 250))
        XCTAssertEqual(Bio.clean(String(repeating: "a", count: 249) + " b"), String(repeating: "a", count: 249))
        XCTAssertEqual(Bio.of(["user_id": "ada", "ext": ["bio": "  "]]), nil)
        XCTAssertEqual(Bio.of(["user_id": "ada", "ext": ["bio": 7]]), nil)
        XCTAssertEqual(Bio.of(["user_id": "ada", "ext": ["bio": "Soup\u{202E}"]]), "Soup")
        XCTAssertEqual(Bio.length("🦆é"), 2)
    }

    // MARK: Status choices

    func testThePickerOffersOptionalStatusesOnlyWhereTheServerListsThem() {
        let values = { (accepted: [String], unsupported: Set<String>, current: String?) in
            StatusChoice.offered(accepted: accepted, unsupported: unsupported, current: current).map(\.value)
        }
        XCTAssertEqual(values([], [], nil), ["online", ""])
        XCTAssertEqual(values(["dnd", "invisible"], [], "online"), ["online", "dnd", "invisible", ""])
        XCTAssertEqual(values(["dnd", "invisible"], ["invisible"], "online"), ["online", "dnd", ""])
        XCTAssertEqual(values([], [], "dnd"), ["online", "dnd", ""], "the current one stays listed")
        XCTAssertEqual(StatusChoice.label(""), "None")
        XCTAssertEqual(StatusChoice.label("away-ish"), "away-ish")
        XCTAssertEqual(StatusChoice.hint(for: nil), "Others see you online, idle or offline, as you come and go.")
        XCTAssertEqual(StatusChoice.hint(for: "away-ish"), "Set by the server. Choose another to replace it.")
    }

    func testTheServersAnswerIsSaidOnlyWhenItKeptAnotherStatus() {
        XCTAssertNil(StatusAnswer(asked: "dnd", kept: "dnd"))
        XCTAssertNil(StatusAnswer(asked: "online", kept: nil))
        let said = { (answer: StatusAnswer?) in answer.map { [$0.title, $0.text] } }
        XCTAssertEqual(said(StatusAnswer(asked: "dnd", kept: "")), ["This server doesn’t offer Do not disturb", "Your status is None."])
        XCTAssertEqual(said(StatusAnswer(asked: "", kept: "online")), ["The server chose another status", "Your status is Online."])
        XCTAssertEqual(said(StatusAnswer(asked: "invisible", error: "Status changes limited")),
                       ["Your status didn’t change", "The server declined Invisible (Status changes limited)."])
    }

    func testStatusWordsSayAnUnknownValueAndYourOwnInvisible() {
        XCTAssertEqual(Presence.words("online", yours: false), "Online")
        XCTAssertEqual(Presence.words("invisible", yours: true), "Invisible · others see you as offline")
        XCTAssertEqual(Presence.words("away-ish", yours: false), "Unknown status: away-ish")
        XCTAssertNil(Presence.words("", yours: false))
        XCTAssertNil(Presence.words(nil, yours: true))
        XCTAssertEqual(Presence(status: "away-ish"), .unknown)
    }

    // MARK: me

    func testChoosingAStatusSendsMeAndKeepsTheChosenOneFromYouOnly() async throws {
        try await signIn(capabilities: ["status"], statuses: ["dnd", "invisible"])
        XCTAssertEqual(session.chosenStatus, "online")
        XCTAssertEqual(session.statusChoices.map(\.value), ["online", "dnd", "invisible", ""])
        let choosing = Task { await session.chooseStatus("invisible") }
        let frame2 = await sent(2)
        XCTAssertEqual(frame2, #"{"id":"c3","method":"me","params":{"status":"invisible"}}"#)
        await socket.deliver(["id": "c3", "result": ["you": ["user_id": "ada", "name": "Ada", "status": "invisible"]]])
        let answer = await choosing.value
        XCTAssertNil(answer)
        XCTAssertEqual(session.chosenStatus, "invisible")
        XCTAssertEqual(session.presence(of: "ada"), .offline)

        await socket.deliver(["method": "user", "params": ["new": ["user_id": "ada", "status": "offline"]]])
        await socket.deliver(["method": "user", "params": ["you": ["user_id": "ada", "name": "Ada L"]]])
        await eventually("renamed") { session.you?.json["name"]?.stringValue == "Ada L" }
        XCTAssertEqual(session.chosenStatus, "invisible", "another object about you never replaces your chosen status")
        await socket.deliver(["method": "user", "params": ["you": ["user_id": "ada", "status": ""]]])
        await eventually("none chosen elsewhere") { session.chosenStatus == "" }
        XCTAssertNil(session.presence(of: "ada"))
    }

    func testAnOptionalStatusTheServerAnswersOtherwiseForIsNotOfferedAgain() async throws {
        try await signIn(capabilities: ["status"], statuses: ["dnd"])
        let choosing = Task { await session.chooseStatus("dnd") }
        _ = await sent(2)
        await socket.deliver(["id": "c3", "result": ["you": ["user_id": "ada", "name": "Ada", "status": ""]]])
        let answer = await choosing.value
        XCTAssertEqual(answer?.title, "This server doesn’t offer Do not disturb")
        XCTAssertEqual(answer?.text, "Your status is None.")
        XCTAssertEqual(session.statusChoices.map(\.value), ["online", ""])

        let refused = Task { await session.chooseStatus("online") }
        _ = await sent(3)
        await socket.deliver(["id": "c4", "error": ["code": -32002, "message": "Status changes limited", "data": ["retry_after": 5]]])
        let refusal = await refused.value
        XCTAssertEqual(refusal?.text, "The server declined Online (Status changes limited).")
        XCTAssertEqual(session.chosenStatus, "", "nothing changes on an error (§4.5.3)")
    }

    func testRemovingTheAvatarSendsAnEmptyOne() async throws {
        try await signIn(capabilities: [], you: ["user_id": "ada", "name": "Ada", "avatar": "https://chat.example/a.png"])
        let removing = Task { try await session.removeAvatar() }
        let frame2 = await sent(2)
        XCTAssertEqual(frame2, #"{"id":"c3","method":"me","params":{"avatar":""}}"#)
        await socket.deliver(["id": "c3", "result": ["you": ["user_id": "ada", "name": "Ada", "avatar": ""]]])
        let removed = try await removing.value
        XCTAssertTrue(removed)
        XCTAssertEqual(session.users.user("ada")?["avatar"]?.stringValue, "")
    }

    // MARK: The form

    func testSavingSendsAChangedBioThenTheNameAndSaysWhatTheServerKept() async throws {
        try await signIn(capabilities: ["ext"], you: ["user_id": "ada", "name": "Ada", "ext": ["bio": "Soup"]])
        var form = ProfileForm(you: session.you)
        XCTAssertEqual(form.bio, "Soup")
        XCTAssertFalse(form.isDirty(keepsBio: true))
        form.name = "  Ada Lovelace "
        form.bio = "Soup,\tmostly."
        XCTAssertTrue(form.isDirty(keepsBio: true))
        let saving = Task { [form] in await session.save(form) }
        let frame2 = await sent(2)
        XCTAssertEqual(frame2, #"{"id":"c3","method":"me","params":{"ext":{"bio":"Soup, mostly."}}}"#)
        await socket.deliver(["id": "c3", "result": ["you": ["user_id": "ada", "name": "Ada", "ext": ["bio": "Soup, mostly."]]]])
        let frame3 = await sent(3)
        XCTAssertEqual(frame3, #"{"id":"c4","method":"me","params":{"name":"Ada Lovelace"}}"#)
        await socket.deliver(["id": "c4", "result": ["you": ["user_id": "ada", "name": "Ada L.", "ext": ["bio": "Soup, mostly."]]]])
        let saved = await saving.value
        XCTAssertEqual(saved.outcome, .altered("Ada L."))
        XCTAssertEqual(saved.name, "Ada L.")
        XCTAssertEqual(saved.bio, "Soup, mostly.")
        XCTAssertFalse(saved.isDirty(keepsBio: true))
        XCTAssertEqual(session.displayName(for: UserObject(["user_id": "ada"])!), "Ada L.")
        XCTAssertEqual(accounts.last??.name, "Ada L.", "the saved account takes the kept name")
    }

    func testARefusedBioStopsTheSaveAndARefusedNameKeepsTheOldOne() async throws {
        try await signIn(capabilities: ["ext:bio"])
        var form = ProfileForm(you: session.you)
        form.bio = String(repeating: "é", count: 200)
        let tooLong = Task { [form] in await session.save(form) }
        _ = await sent(2)
        await socket.deliver(["id": "c3", "error": ["code": -32003, "message": "Too large"]])
        let refused = await tooLong.value
        XCTAssertEqual(refused.bioError, "Your bio is too long for this server. Try a shorter one.")
        XCTAssertEqual(refused.outcome, .none)

        var renamed = ProfileForm(you: session.you)
        renamed.name = "Ada!"
        let declining = Task { [renamed] in await session.save(renamed) }
        let frame3 = await sent(3)
        XCTAssertEqual(frame3, #"{"id":"c4","method":"me","params":{"name":"Ada!"}}"#, "an unchanged bio is not sent")
        await socket.deliver(["id": "c4", "error": ["code": -32001, "message": "Only registered users may change their name"]])
        let declined = await declining.value
        XCTAssertEqual(declined.outcome, .declined("The server declined this name (Only registered users may change their name). Your old one is still in use."))
        XCTAssertEqual(session.you?.json["name"]?.stringValue, "Ada")
    }

    func testWithoutABioTheFormIgnoresIt() async throws {
        try await signIn(capabilities: [])
        XCTAssertFalse(session.keepsBio)
        var form = ProfileForm(you: session.you)
        form.bio = "Soup"
        XCTAssertFalse(form.isDirty(keepsBio: false))
        let unchanged = await session.save(form)
        XCTAssertEqual(unchanged.outcome, .none)
        let frames = await socket.sentLog.count
        XCTAssertEqual(frames, 2, "nothing to send")
        form.revert()
        XCTAssertEqual(form.bio, "")
    }
}
