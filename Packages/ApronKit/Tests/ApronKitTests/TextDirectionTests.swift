import ApronKit
import XCTest

final class TextDirectionTests: XCTestCase {
    func testTheFirstStrongLetterGivesTheDirection() {
        XCTAssertEqual(TextDirection(of: "مرحبا بالجميع"), .rightToLeft)
        XCTAssertEqual(TextDirection(of: "12:30 שלום, hi"), .rightToLeft, "digits and punctuation are not strong")
        XCTAssertEqual(TextDirection(of: "ship it שלום"), .leftToRight)
        XCTAssertEqual(TextDirection(of: "Ἀθῆναι"), .leftToRight)
        XCTAssertNil(TextDirection(of: "👍 12:30"))
    }

    func testOverridesAreDroppedAndStringsIsolated() {
        XCTAssertEqual(TextDirection.withoutOverrides("evil\u{202E}gnp.exe"), "evilgnp.exe")
        XCTAssertEqual(TextDirection.withoutOverrides("\u{202A}a\u{202B}b\u{202C}c\u{202D}d"), "abcd")
        XCTAssertEqual(TextDirection.withoutOverrides("\u{2067}kept\u{2069}"), "\u{2067}kept\u{2069}", "isolates are not overrides")
        XCTAssertEqual(TextDirection.isolated("a\u{202E}b"), "\u{2068}ab\u{2069}")
    }

    func testNamesTitlesAndMessagesShowWithoutOverrides() {
        var users = UserDirectory()
        users.replace(with: UserObject(["user_id": "mallory", "name": "Mal\u{202E}lory"])!)
        XCTAssertEqual(users.displayName(for: UserObject(["user_id": "mallory"])!), "Mallory")
        users.replace(with: UserObject(["user_id": "other", "name": "Mal\u{202E}lory"])!)
        XCTAssertEqual(users.displayName(for: UserObject(["user_id": "mallory"])!), "\u{2068}Mallory\u{2069} (@mallory)")

        let text = MessageText.attributed(["text": "invoice\u{202E}fdp.exe"])
        XCTAssertEqual(String(text.characters), "invoicefdp.exe")
    }
}
