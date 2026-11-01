import XCTest
@testable import ApronKit

/// The terminal model against what apron-web's xterm.js shows for the same bytes (§4.8.6).
final class TerminalScreenTests: XCTestCase {
    private func lines(_ output: String, scrollback: Int = 0) -> [String] {
        TerminalScreen.showing(output, scrollback: scrollback).plainText.components(separatedBy: "\n")
    }

    private func cell(_ screen: TerminalScreen, _ row: Int, _ column: Int) -> TerminalCell { screen.screen[row][column] }

    func testALineFeedAlsoReturnsToTheFirstColumn() {
        XCTAssertEqual(lines("one\ntwo\n"), ["one", "two"])
    }

    func testACarriageReturnDrawsOverItsLine() {
        XCTAssertEqual(lines("Downloading  10%\rDownloading 100%\r\ndone"), ["Downloading 100%", "done"])
        XCTAssertEqual(lines("abc\rX"), ["Xbc"])
    }

    func testBackspaceTabAndEraseInLine() {
        XCTAssertEqual(lines("ab\u{08}c\td"), ["ac      d"])
        XCTAssertEqual(lines("hello world\r\u{1B}[6C\u{1B}[K"), ["hello"])
        XCTAssertEqual(lines("hello\u{1B}[2D\u{1B}[1K"), ["    o"])
    }

    func testTheCursorMovesUpToRewriteALineAndBack() {
        let output = "  … store running\r\n  … http running\r\n\u{1B}[2A\r\u{1B}[2K  ✓ store ok\u{1B}[2B\rdone"
        XCTAssertEqual(lines(output), ["  ✓ store ok", "  … http running", "done"])
    }

    func testCursorPositionAndEraseInDisplay() {
        XCTAssertEqual(lines("xxxx\r\nyyyy\u{1B}[2J\u{1B}[2;3Hz"), ["", "  z"])
        XCTAssertEqual(lines("abc\u{1B}[1;2H\u{1B}[P"), ["ac"], "DCH pulls the rest of the line left")
        XCTAssertEqual(lines("abc\u{1B}[1;2H\u{1B}[2@"), ["a  bc"], "ICH pushes it right")
    }

    func testColorsAndAttributes() {
        let screen = TerminalScreen.showing("\u{1B}[1;31mA\u{1B}[0;38;5;208mB\u{1B}[48;2;1;2;3mC\u{1B}[38:2::9:8:7mD\u{1B}[92;7mE\u{1B}[0mF")
        XCTAssertEqual(cell(screen, 0, 0).style, TerminalStyle(foreground: .indexed(1), attributes: .bold))
        XCTAssertEqual(cell(screen, 0, 1).style, TerminalStyle(foreground: .indexed(208)))
        XCTAssertEqual(cell(screen, 0, 2).style, TerminalStyle(foreground: .indexed(208), background: .rgb(1, 2, 3)))
        XCTAssertEqual(cell(screen, 0, 3).style.foreground, .rgb(9, 8, 7), "the colon form with a color space id")
        XCTAssertEqual(cell(screen, 0, 4).style, TerminalStyle(foreground: .indexed(10), background: .rgb(1, 2, 3), attributes: .inverse))
        XCTAssertEqual(cell(screen, 0, 5).style, TerminalStyle())
        XCTAssertEqual(TerminalColor.xterm(16)! == (0, 0, 0), true)
        XCTAssertEqual(TerminalColor.xterm(196)! == (255, 0, 0), true)
        XCTAssertEqual(TerminalColor.xterm(244)! == (128, 128, 128), true)
    }

    func testASequenceCutBetweenWritesStillApplies() {
        var screen = TerminalScreen()
        for piece in ["\u{1B}", "[3", "2m", "ok", "\u{1B}]0;ti", "tle\u{07}", "!"] { screen.write(piece) }
        XCTAssertEqual(screen.plainText, "ok!")
        XCTAssertEqual(screen.screen[0][0].style.foreground, .indexed(2))
    }

    func testNothingOutsideTheScreenActsAndNoEscapeShowsAsText() {
        let output = "\u{1B}]0;make test\u{07}\u{1B}]52;c;aGVsbG8=\u{07}\u{07}\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\\u{1B}[6n\u{1B}[c\u{1B}P1;2q\u{1B}\\."
        XCTAssertEqual(lines(output), ["link."])
    }

    func testLineDrawingAndWideCharacters() {
        XCTAssertEqual(lines("\u{1B}(0lqqk\r\nx  x\r\nmqqj\u{1B}(B"), ["┌──┐", "│  │", "└──┘"])
        let screen = TerminalScreen.showing("日本a")
        XCTAssertEqual(screen.plainText, "日本a")
        XCTAssertTrue(cell(screen, 0, 1).isContinuation)
        XCTAssertEqual(cell(screen, 0, 4).text, "a")
        XCTAssertEqual(TerminalScreen.showing("e\u{301}x").screen[0][0].text, "e\u{301}", "a combining mark joins its letter")
    }

    func testTheEightiethColumnWrapsOnTheNextCharacter() {
        let full = String(repeating: "a", count: 80)
        XCTAssertEqual(lines(full + "b"), [full, "b"])
        XCTAssertEqual(lines(full + "\r\nb"), [full, "b"], "a line feed at the edge makes no blank line")
    }

    func testRowsShowDownToTheLastWrittenUnlessAProgramTookTheScreen() {
        XCTAssertEqual(TerminalScreen.showing("a\r\nb\r\n").shownRowCount, 2)
        XCTAssertEqual(TerminalScreen.showing("a\r\n\u{1B}[44m \u{1B}[0m").shownRowCount, 2, "a colored blank is written")
        XCTAssertEqual(TerminalScreen.showing("").shownRowCount, 1)
        XCTAssertEqual(TerminalScreen.showing("\u{1B}[?1049hfull screen").shownRowCount, 40)
        XCTAssertEqual(TerminalScreen.showing(String(repeating: "x\n", count: 45)).shownRowCount, 40)
    }

    func testTheAlternateScreenComesBackToTheMainOne() {
        let screen = TerminalScreen.showing("shell$ \u{1B}[?1049h\u{1B}[Hvim\u{1B}[?1049lback")
        XCTAssertFalse(screen.isAlternate)
        XCTAssertEqual(screen.plainText, "shell$ back")
    }

    func testAMessageKeepsNoScrollbackAndTheViewerKeepsLines() {
        let output = (1...45).map(String.init).joined(separator: "\n")
        XCTAssertEqual(lines(output).first, "6")
        XCTAssertEqual(lines(output, scrollback: TerminalScreen.viewerScrollback).count, 45)
        XCTAssertEqual(TerminalScreen.showing(output, scrollback: 3).scrollback.count, 3)
    }

    func testAScrollRegionKeepsTheLinesOutsideIt() {
        let output = "head\r\n\u{1B}[2;3r\u{1B}[2;1Ha\r\nb\r\nc\u{1B}[r"
        XCTAssertEqual(lines(output), ["head", "b", "c"])
    }

    func testResetStartsAFreshTerminal() {
        var screen = TerminalScreen.showing("\u{1B}[31mold")
        screen.write("\u{1B}cnew")
        XCTAssertEqual(screen.plainText, "new")
        XCTAssertEqual(screen.screen[0][0].style, TerminalStyle())
    }

    func testApronWebsDemoRendersAsATerminalWouldShowIt() async {
        let read = PreviewFixtures.readLiveText(PreviewFixtures.liveTerminalURL)
        var decoder = LiveTextDecoder()
        var screen = TerminalScreen()
        var iterator = read.makeAsyncIterator()
        while let event = try? await iterator.next() {
            if case .bytes(let data) = event { screen.write(decoder.decode(data)) }
            if screen.plainText.contains("ramping") { break }
        }
        let shown = screen.plainText.components(separatedBy: "\n")
        XCTAssertEqual(shown[0], "$ make ramp")
        XCTAssertEqual(shown[1], "┌" + String(repeating: "─", count: 78) + "┐")
        XCTAssertEqual(shown[4], "  ✓ store      ok  42 tests  0.41s")
        XCTAssertEqual(shown[6], "  ✓ http       ok  25 tests  0.63s")
        XCTAssertEqual(shown[7], "  coverage " + String(repeating: "█", count: 20) + " 100%")
        XCTAssertEqual(shown[12], "  bold dim italic underline inverse struck  a link that opens nothing")
        XCTAssertEqual(shown[14], "PASS 3 packages, 128 tests, 0 failures in 2.11s")
        XCTAssertEqual(screen.screen[2][0].text, "│")
        XCTAssertEqual(screen.screen[9][13].style.foreground, .indexed(0), "the 16 colors row starts at black")
        XCTAssertEqual(screen.screen[10][13].style.background, .indexed(196))
        XCTAssertEqual(screen.screen[11][13].style.background, .rgb(0x8F, 0xB0, 0xF5))
    }
}
