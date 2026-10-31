@testable import ApronKit
import XCTest

final class PreferencesSectionTests: XCTestCase {
    func testSectionsAreApronWebsInItsOrder() {
        XCTAssertEqual(PreferencesSection.allCases.map(\.rawValue), ["profile", "notifications", "appearance", "media", "history"])
        XCTAssertEqual(PreferencesSection(rawValue: "media"), .media)
        XCTAssertNil(PreferencesSection(rawValue: "nope"))
    }

    /// apron-web's `preferences` key is its own page address, not a link.apron.chat key.
    func testALinkNamingOnlyASectionIsNoLinkAndTheKeyStaysBesideAPlace() {
        XCTAssertNil(ApronLink("apron:?preferences=appearance"))
        XCTAssertNil(ApronLink("https://link.apron.chat/#preferences=media"))
        let link = ApronLink("https://link.apron.chat/#server=wss://chat.example/ws&room=general&preferences=notifications")
        XCTAssertEqual(link?.room, "general")
        XCTAssertEqual(link?.otherKeys, [ApronLink.Pair(key: "preferences", value: "notifications")])
    }
}
