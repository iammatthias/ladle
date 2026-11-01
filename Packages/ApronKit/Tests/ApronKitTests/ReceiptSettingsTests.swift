import XCTest
@testable import ApronKit

/// Read Receipts on this device: on by default, kept beside `servers.json`, and back on it
/// tells the store, which has every server send the cursors it held back.
@MainActor
final class ReceiptSettingsTests: XCTestCase {
    func testTheChoiceIsKeptAndTurningItBackOnIsHeard() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = ReceiptSettings(directory: directory)
        XCTAssertTrue(settings.isOn)
        var heard = 0
        settings.onTurnedOn = { heard += 1 }
        settings.set(false)
        XCTAssertFalse(ReceiptSettings(directory: directory).isOn)
        settings.set(true)
        settings.set(true)
        XCTAssertEqual(heard, 1, "only a change from off")
        XCTAssertTrue(ReceiptSettings(directory: directory).isOn)
    }
}
