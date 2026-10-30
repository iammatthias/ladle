import Synchronization
import XCTest
@testable import ApronKit

/// Records what was scheduled and cancelled, and answers with `allowed`.
private final class RecordingNotifier: ReminderNotifier {
    let allowed: Bool
    let log = Mutex<[String]>([])

    init(allowed: Bool = true) { self.allowed = allowed }

    func schedule(_ reminder: Reminder) async -> Bool {
        log.withLock { $0.append("schedule \(reminder.key.identifier) at \(Int(reminder.due.timeIntervalSince1970))") }
        return allowed
    }

    func cancel(_ identifiers: [String]) async {
        log.withLock { $0.append("cancel \(identifiers.joined(separator: ","))") }
    }

    var entries: [String] { log.withLock { $0 } }
}

@MainActor
final class RemindersTests: XCTestCase {
    private let server = UUID(uuidString: "6C61646C-0000-4000-8000-000000000001")!
    private var key: ReminderKey { ReminderKey(server: server, roomID: "general", messageID: LogID("1793091900000")!) }

    private func reminder(at seconds: TimeInterval, _ key: ReminderKey? = nil) -> Reminder {
        Reminder(key: key ?? self.key, due: Date(timeIntervalSince1970: seconds), title: "Ada Okafor in #general", body: "Notes from the sync")
    }

    func testTheChoicesAreDueFromNow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        // 2026-10-29 18:40 in Los Angeles (01:40 UTC the next day).
        let now = Date(timeIntervalSince1970: 1_793_324_400)
        XCTAssertEqual(ReminderChoice.allCases.map { $0.due(after: now, calendar: calendar).timeIntervalSince1970 }, [
            1_793_324_700, 1_793_326_200, 1_793_328_000, 1_793_335_200,
            1_793_376_000, // 2026-10-30 09:00 in Los Angeles
        ])
        XCTAssertEqual(ReminderChoice.allCases.map(\.title), ["In 5 Minutes", "In 30 Minutes", "In 1 Hour", "In 3 Hours", "Tomorrow"])
    }

    func testTheRowSaysWhenItIsDue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func label(_ seconds: TimeInterval) -> String { Reminder.label(due: now.addingTimeInterval(seconds), now: now) }
        XCTAssertEqual(label(299), "Due in 5 min")
        XCTAssertEqual(label(59 * 60 + 1), "Due in 1 hr", "60 minutes reads as an hour")
        XCTAssertEqual(label(3600), "Due in 1 hr")
        XCTAssertEqual(label(3 * 3600 - 60), "Due in 3 hr")
        XCTAssertEqual(label(36 * 3600), "Due in 2 days")
        XCTAssertEqual(label(24 * 3600), "Due in 1 day")
        XCTAssertEqual(label(0), "Due now")
        XCTAssertEqual(label(-600), "Due now")
    }

    func testSettingAgainReplacesAndRemovingCancels() async {
        let notifier = RecordingNotifier()
        let store = InMemoryReminderStore()
        let reminders = Reminders(store: store, notifier: notifier)
        let id = "reminder:6C61646C-0000-4000-8000-000000000001:1793091900000:general"
        XCTAssertEqual(key.identifier, id)
        let scheduled = await reminders.set(reminder(at: 2_000_000))
        XCTAssertTrue(scheduled)
        await reminders.set(reminder(at: 2_000_600))
        XCTAssertEqual(reminders[key]?.due, Date(timeIntervalSince1970: 2_000_600))
        XCTAssertEqual(store.load().map(\.due), [Date(timeIntervalSince1970: 2_000_600)], "one per message")
        await reminders.remove(key)
        XCTAssertNil(reminders[key])
        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(notifier.entries, ["schedule \(id) at 2000000", "schedule \(id) at 2000600", "cancel \(id)"])
    }

    func testATappedNotificationNamesItsMessage() {
        XCTAssertEqual(ReminderKey(userInfo: key.userInfo), key)
        XCTAssertEqual(key.userInfo, ["server": "6C61646C-0000-4000-8000-000000000001", "room": "general", "message": "1793091900000"])
        XCTAssertNil(ReminderKey(userInfo: ["server": "6C61646C-0000-4000-8000-000000000001", "room": "general", "message": "x"]))
        XCTAssertNil(ReminderKey(userInfo: [:]))
    }

    func testADeniedReminderIsKeptForItsRow() async {
        let reminders = Reminders(store: InMemoryReminderStore(), notifier: RecordingNotifier(allowed: false))
        let scheduled = await reminders.set(reminder(at: 2_000_000))
        XCTAssertFalse(scheduled)
        XCTAssertNotNil(reminders[key])
    }

    func testRemindersOutliveALaunchInTheirFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = ReminderKey(server: UUID(), roomID: "#ops/alerts", messageID: LogID("7")!)
        let first = Reminders(store: FileReminderStore(directory: directory), notifier: RecordingNotifier())
        await first.set(reminder(at: 2_000_000))
        await first.set(reminder(at: 1_500_000, other))
        let second = Reminders(store: FileReminderStore(directory: directory), notifier: RecordingNotifier())
        XCTAssertEqual(second.byKey, [key: reminder(at: 2_000_000), other: reminder(at: 1_500_000, other)])
        let notifier = RecordingNotifier()
        let third = Reminders(store: FileReminderStore(directory: directory), notifier: notifier)
        await third.removeAll(server: server)
        XCTAssertEqual(Array(third.byKey.keys), [other])
        XCTAssertEqual(notifier.entries, ["cancel \(key.identifier)"])
    }

    func testRemovingAServerRemovesItsReminders() async throws {
        let store = await PreviewFixtures.makeStore()
        let home = try XCTUnwrap(store.session(for: PreviewFixtures.homeID))
        let message = try XCTUnwrap(home.timeline("general").first { $0.body?["text"]?.stringValue?.hasPrefix("Notes from the sync") == true })
        let made = home.reminder(for: message, due: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(made.title, "Ada Okafor in #general")
        XCTAssertEqual(made.body, "Notes from the sync: ship 0.2 on Friday, then freeze. The release checklist lives in the thread. Please add anything I…")
        XCTAssertEqual(made.key, ReminderKey(server: PreviewFixtures.homeID, roomID: "general", messageID: message.messageID))
        let thread = try XCTUnwrap(home.timeline("1793092125000").first)
        XCTAssertEqual(home.reminder(for: thread, due: .now).title, "Ada Okafor in Release 0.2", "a thread by its title alone")
        await store.reminders.set(made)
        await store.remove(PreviewFixtures.homeID)
        XCTAssertTrue(store.reminders.byKey.isEmpty)
    }
}
