import XCTest
@testable import ApronKit

/// The protocol's terminal fixtures (tests/fixtures/terminal.json, §4.8.6): every case's output
/// from a fresh 80×40 screen, at every level, against its expected screen and cells, text in NFC.
final class TerminalFixtureTests: XCTestCase {
    func testEveryCaseShowsItsExpectedScreen() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "terminal", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONValue(parsing: Data(contentsOf: url))
        XCTAssertEqual(fixture["format"]?.intValue, 1)
        let cases = try XCTUnwrap(fixture["cases"]?.arrayValue)
        var levels: [String: Int] = [:]
        for item in cases {
            let name = item["name"]?.stringValue ?? "?"
            levels[item["level"]?.stringValue ?? "?", default: 0] += 1
            let output = try XCTUnwrap(item["output"]?.stringValue, name)
            let expected = try XCTUnwrap(item["expected"], name)
            let screen = TerminalScreen.showing(output)
            XCTAssertEqual(Self.shown(screen), expected["screen"]?.arrayValue?.compactMap { $0.stringValue?.nfc }, name)
            for want in expected["cells"]?.arrayValue ?? [] {
                let row = try XCTUnwrap(want["row"]?.intValue), column = try XCTUnwrap(want["col"]?.intValue)
                XCTAssertEqual(Self.described(screen.screen[row][column]), Self.described(want), "\(name) at \(row),\(column)")
            }
        }
        print("terminal fixtures: \(cases.count) cases, \(levels.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))")
        XCTAssertEqual(levels, ["MUST": 5, "SHOULD": 8, "terminal": 7])
    }

    /// The fixture's `screen`: rows from the top down to the last with text, trailing spaces
    /// dropped, a wide character once.
    private static func shown(_ screen: TerminalScreen) -> [String] {
        var rows = screen.screen.map { row in
            String(row.filter { !$0.isContinuation }.map(\.text).joined().reversed().drop { $0 == " " }.reversed()).nfc
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows
    }

    /// A cell as the fixture writes one: its char, and only the attributes that are set.
    private static func described(_ cell: TerminalCell) -> [String: String] {
        var out = ["char": cell.text.nfc]
        if let fg = color(cell.style.foreground) { out["fg"] = fg }
        if let bg = color(cell.style.background) { out["bg"] = bg }
        let names: [(TerminalStyle.Attributes, String)] = [
            (.bold, "bold"), (.dim, "dim"), (.italic, "italic"), (.underline, "underline"), (.inverse, "inverse"), (.strikethrough, "strikethrough"),
        ]
        for (attribute, name) in names where cell.style.attributes.contains(attribute) { out[name] = "true" }
        return out
    }

    private static func described(_ want: JSONValue) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in want.objectValue ?? [:] where key != "row" && key != "col" {
            out[key] = value.stringValue.map { key == "char" ? $0.nfc : $0.lowercased() } ?? value.intValue.map(String.init) ?? value.boolValue.map { "\($0)" }
        }
        return out
    }

    private static func color(_ color: TerminalColor) -> String? {
        switch color {
        case .default: nil
        case .indexed(let index): String(index)
        case .rgb(let r, let g, let b): "#" + [r, g, b].map { String(format: "%02x", $0) }.joined()
        }
    }
}

private extension String {
    var nfc: String { precomposedStringWithCanonicalMapping }
}
