import ApronKit
import XCTest

final class ItalicTests: XCTestCase {
    private let wght = FontAxis(tag: "wght", minimum: 400, maximum: 800)

    func testTheBundledFacesAndSFRoundedAreDrawnObliqueAtFourteenDegrees() {
        // Nunito, Recursive's casual sans and mono as fonts.py converts them: one `wght` axis each.
        XCTAssertEqual(Italic.choose(hasItalicFace: false, axes: [wght]), .oblique(skew: 0.2493280028431807))
        // SF Rounded: `wght` and `GRAD`, no italic cut.
        let rounded = [FontAxis(tag: "GRAD", minimum: 400, maximum: 1000), FontAxis(tag: "wght", minimum: 1, maximum: 1000)]
        XCTAssertEqual(Italic.choose(hasItalicFace: false, axes: rounded), .oblique(skew: 0.2493280028431807))
    }

    func testAnItalicCutWinsOverAnyAxis() {
        XCTAssertEqual(Italic.choose(hasItalicFace: true, axes: [FontAxis(tag: "ital", minimum: 0, maximum: 1)]), .face)
    }

    func testAnItalAxisIsSetToOne() {
        XCTAssertEqual(Italic.choose(hasItalicFace: false, axes: [wght, FontAxis(tag: "ital", minimum: 0, maximum: 1)]), .axis(tag: "ital", value: 1))
    }

    func testASlntAxisAloneIsNotItalic() {
        // CSS gives `slnt` to oblique values and `ital` to italic (CSS Fonts 4 §2.4).
        let slnt = FontAxis(tag: "slnt", minimum: -15, maximum: 0)
        XCTAssertEqual(Italic.choose(hasItalicFace: false, axes: [wght, slnt]), .oblique(skew: 0.2493280028431807))
    }

    func testAxisTagsRoundTripCoreTextNumbers() {
        XCTAssertEqual(FontAxis.code("wght"), 0x7767_6874)
        XCTAssertEqual(FontAxis.code("ital"), 0x6974_616C)
        XCTAssertEqual(FontAxis.tag(0x736C_6E74), "slnt")
        XCTAssertEqual(FontAxis.tag(1_196_572_996), "GRAD")
    }
}
