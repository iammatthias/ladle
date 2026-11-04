import Foundation

/// A terminal embed's screen (v10 §4.8.6), as apron-web draws it with xterm.js: 80 columns by 40
/// rows, read only. `write` takes decoded text as it arrives, cut anywhere, a control sequence
/// included. It covers what apron-web's terminals show: SGR colors (16, 256 and true color) and
/// attributes, carriage return, backspace, tab, cursor movement, erasing, inserting and deleting,
/// scroll regions, the alternate screen, DEC line drawing and wide characters. A line feed also
/// returns to the first column, as the spec says. Title, clipboard, bell, links and reports are
/// parsed and dropped: nothing a program prints acts outside the screen.
public struct TerminalScreen: Sendable {
    public static let columns = 80
    public static let rows = 40

    /// The lines kept above the screen, at most `scrollbackLimit`. A message's screen keeps none;
    /// the full-screen viewer keeps `viewerScrollback`.
    public private(set) var scrollback: [TerminalLine] = []
    public let scrollbackLimit: Int
    public static let viewerScrollback = 5000

    private var main: [TerminalLine]
    private var alternate: [TerminalLine]?
    private var cursor = Position()
    private var saved = Position()
    private var mainSaved = Position()
    private var style = TerminalStyle()
    private var pendingWrap = false
    private var autowrap = true
    private var top = 0
    private var bottom = TerminalScreen.rows - 1
    private var graphicsG0 = false
    private var graphicsG1 = false
    private var shifted = false
    private var parser = Parser.ground
    private var previous: String?
    /// A line scrolled off the top of the main screen since the last reset.
    private var scrolled = false

    private struct Position: Sendable {
        var row = 0
        var column = 0
        var style = TerminalStyle()
        var graphics = false
    }

    private enum Parser: Sendable {
        case ground
        case escape(intermediates: String)
        case csi(String)
        /// OSC, DCS, SOS, PM and APC: skipped to BEL (OSC only) or ST.
        case string(acceptsBell: Bool, sawEscape: Bool)
    }

    public init(scrollback: Int = 0) {
        scrollbackLimit = scrollback
        main = Self.blankScreen()
    }

    /// The initial state of a terminal: default colors and attributes, nothing on screen.
    public mutating func reset() {
        self = TerminalScreen(scrollback: scrollbackLimit)
    }

    /// `output` from a fresh terminal, such as a finished embed's.
    public static func showing(_ output: String, scrollback: Int = 0) -> TerminalScreen {
        var screen = TerminalScreen(scrollback: scrollback)
        screen.write(output)
        return screen
    }

    /// The rows on screen now.
    public var screen: [TerminalLine] { alternate ?? main }

    public var isAlternate: Bool { alternate != nil }

    /// The rows to show, as apron-web's `shownRows`: all 40 on the alternate screen or once a
    /// line has scrolled off, else down to the last one written (text, or a colored blank), at
    /// least one.
    public var shownRowCount: Int {
        if alternate != nil || scrolled { return Self.rows }
        for row in stride(from: Self.rows - 1, to: 0, by: -1) where main[row].contains(where: \.isWritten) { return row + 1 }
        return 1
    }

    /// What the screen shows as plain text, scrollback first, as apron-web's `bufferText`: the
    /// escapes already acted on, a line that wrapped joined to the one before it, the blanks at
    /// each line's end and the blank lines at the foot dropped. What VoiceOver reads and Copy takes.
    public var plainText: String {
        let rows = scrollback + screen
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            let text = row.filter { !$0.isContinuation }.map(\.text).joined()
            // A line that goes on into the next keeps the spaces written at its end.
            let continues = index + 1 < rows.count && rows[index + 1].isWrapped
            let kept = continues ? text : text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if row.isWrapped, !lines.isEmpty { lines[lines.count - 1] += kept } else { lines.append(kept) }
        }
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Writing

    public mutating func write(_ text: String) {
        for scalar in text.unicodeScalars { feed(scalar) }
    }

    private mutating func feed(_ scalar: Unicode.Scalar) {
        let value = scalar.value
        switch parser {
        case .ground:
            break
        case .escape(let intermediates):
            if value < 0x20 && value != 0x1B { control(scalar); return }
            escape(scalar, intermediates: intermediates)
            return
        case .csi(let body):
            if value == 0x1B { parser = .escape(intermediates: ""); return }
            if value < 0x20 { control(scalar); return }
            if (0x40...0x7E).contains(value) {
                parser = .ground
                csi(body, final: scalar)
            } else {
                parser = .csi(body + String(scalar))
            }
            return
        case .string(let acceptsBell, let sawEscape):
            if value == 0x07 && acceptsBell { parser = .ground; return }
            if sawEscape && scalar == "\\" { parser = .ground; return }
            if value == 0x18 || value == 0x1A { parser = .ground; return }
            parser = .string(acceptsBell: acceptsBell, sawEscape: value == 0x1B)
            return
        }
        if value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value) {
            control(scalar)
        } else {
            print(scalar)
        }
    }

    private mutating func control(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x08:
            pendingWrap = false
            cursor.column = max(0, cursor.column - 1)
        case 0x09:
            pendingWrap = false
            cursor.column = min(Self.columns - 1, (cursor.column / 8 + 1) * 8)
        case 0x0A, 0x0B, 0x0C:
            lineFeed()
            rows[cursor.row].isWrapped = false
            cursor.column = 0
        case 0x0D:
            pendingWrap = false
            cursor.column = 0
        case 0x0E: shifted = true
        case 0x0F: shifted = false
        case 0x18, 0x1A: parser = .ground
        case 0x1B: parser = .escape(intermediates: "")
        case 0x9B: parser = .csi("")
        case 0x90, 0x98, 0x9E, 0x9F: parser = .string(acceptsBell: false, sawEscape: false)
        case 0x9D: parser = .string(acceptsBell: true, sawEscape: false)
        default: break
        }
    }

    private mutating func escape(_ scalar: Unicode.Scalar, intermediates: String) {
        let value = scalar.value
        if (0x20...0x2F).contains(value) {
            parser = .escape(intermediates: intermediates + String(scalar))
            return
        }
        parser = .ground
        switch intermediates {
        case "":
            switch scalar {
            case "[": parser = .csi("")
            case "]", "X", "^", "_": parser = .string(acceptsBell: scalar == "]", sawEscape: false)
            case "P": parser = .string(acceptsBell: false, sawEscape: false)
            case "c": reset()
            case "7": saveCursor()
            case "8": restoreCursor()
            case "D": lineFeed()
            case "E": lineFeed(); cursor.column = 0
            case "M": reverseIndex()
            default: break
            }
        case "(": graphicsG0 = scalar == "0"
        case ")": graphicsG1 = scalar == "0"
        default: break
        }
    }

    private mutating func print(_ scalar: Unicode.Scalar) {
        var scalar = scalar
        if shifted ? graphicsG1 : graphicsG0, let drawn = Self.lineDrawing[scalar] { scalar = drawn }
        let width = TerminalWidth.of(scalar)
        if width == 0 {
            appendToPrevious(scalar)
            return
        }
        if pendingWrap {
            if autowrap { wrap() }
            pendingWrap = false
        }
        if width == 2 && cursor.column == Self.columns - 1 {
            if autowrap {
                // An empty cell, as xterm leaves: not a space the text holds.
                put(TerminalCell(text: "", style: style), at: cursor.column)
                wrap()
            } else {
                return
            }
        }
        put(TerminalCell(text: String(scalar), style: style, width: width), at: cursor.column)
        if width == 2 { put(TerminalCell(text: "", style: style, isContinuation: true), at: cursor.column + 1) }
        previous = String(scalar)
        if cursor.column + width >= Self.columns {
            cursor.column = Self.columns - 1
            pendingWrap = true
        } else {
            cursor.column += width
        }
    }

    /// Goes on to the next line, which continues this one.
    private mutating func wrap() {
        lineFeed()
        cursor.column = 0
        rows[cursor.row].isWrapped = true
    }

    /// A combining mark, a joiner or a variation selector joins the character before it.
    private mutating func appendToPrevious(_ scalar: Unicode.Scalar) {
        var column = pendingWrap ? cursor.column : cursor.column - 1
        guard column >= 0 else { return }
        let row = cursor.row
        if rows[row][column].isContinuation, column > 0 { column -= 1 }
        rows[row][column].text.unicodeScalars.append(scalar)
    }

    /// The screen being written: the alternate one while a program uses it.
    private var rows: [TerminalLine] {
        get { alternate ?? main }
        _modify {
            if alternate != nil { yield &alternate! } else { yield &main }
        }
    }

    private mutating func put(_ cell: TerminalCell, at column: Int) {
        guard column < Self.columns else { return }
        let row = cursor.row
        do {
            // Writing over half of a wide character blanks its other half.
            if rows[row][column].isContinuation, column > 0 { rows[row][column - 1] = TerminalCell(text: " ", style: rows[row][column - 1].style) }
            if rows[row][column].width == 2, column + 1 < Self.columns, !cell.isContinuation {
                rows[row][column + 1] = TerminalCell(text: " ", style: rows[row][column + 1].style)
            }
            rows[row][column] = cell
        }
    }

    // MARK: Movement and scrolling

    private mutating func lineFeed() {
        pendingWrap = false
        if cursor.row == bottom {
            scrollUp(1)
        } else if cursor.row < Self.rows - 1 {
            cursor.row += 1
        }
    }

    private mutating func reverseIndex() {
        pendingWrap = false
        if cursor.row == top { scrollDown(1) } else if cursor.row > 0 { cursor.row -= 1 }
    }

    private func blankLine() -> TerminalLine {
        TerminalLine(cells: Array(repeating: TerminalCell(text: " ", style: style.erased), count: Self.columns))
    }

    private mutating func scrollUp(_ count: Int) {
        let count = min(count, bottom - top + 1)
        guard count > 0 else { return }
        if alternate == nil, top == 0 {
            scrolled = true
            if scrollbackLimit > 0 {
                scrollback.append(contentsOf: main[0..<count])
                if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
            }
        }
        let blank = blankLine()
        do {
            rows.removeSubrange(top..<(top + count))
            rows.insert(contentsOf: Array(repeating: blank, count: count), at: bottom - count + 1)
        }
    }

    private mutating func scrollDown(_ count: Int) {
        let count = min(count, bottom - top + 1)
        guard count > 0 else { return }
        let blank = blankLine()
        do {
            rows.removeSubrange((bottom - count + 1)...bottom)
            rows.insert(contentsOf: Array(repeating: blank, count: count), at: top)
        }
    }

    private mutating func moveTo(row: Int, column: Int) {
        pendingWrap = false
        cursor.row = max(0, min(Self.rows - 1, row))
        cursor.column = max(0, min(Self.columns - 1, column))
    }

    private mutating func saveCursor() {
        saved = Position(row: cursor.row, column: cursor.column, style: style, graphics: graphicsG0)
    }

    private mutating func restoreCursor() {
        cursor.row = saved.row
        cursor.column = saved.column
        style = saved.style
        graphicsG0 = saved.graphics
        pendingWrap = false
    }

    // MARK: Control sequences

    private mutating func csi(_ body: String, final: Unicode.Scalar) {
        var body = Substring(body)
        let marker = body.first.flatMap { "?<=>".contains($0) ? $0 : nil }
        if marker != nil { body = body.dropFirst() }
        let intermediates = body.drop { !(" !\"#$%&'()*+,-./".contains($0)) }
        if !intermediates.isEmpty { return }
        let groups = body.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let params = groups.map { Int($0.split(separator: ":").first ?? "") }
        func at(_ index: Int, _ fallback: Int = 1) -> Int {
            guard index < params.count, let value = params[index], value != 0 else { return fallback }
            return value
        }
        if marker == "?" {
            if final == "h" || final == "l" { privateMode(params.compactMap { $0 }, on: final == "h") }
            return
        }
        guard marker == nil else { return }
        let row = cursor.row
        let column = cursor.column
        switch final {
        case "A": moveTo(row: max(row - at(0), row >= top ? top : 0), column: column)
        case "B", "e": moveTo(row: min(row + at(0), row <= bottom ? bottom : Self.rows - 1), column: column)
        case "C", "a": moveTo(row: row, column: column + at(0))
        case "D": moveTo(row: row, column: column - at(0))
        case "E": moveTo(row: min(row + at(0), bottom), column: 0)
        case "F": moveTo(row: max(row - at(0), top), column: 0)
        case "G", "`": moveTo(row: row, column: at(0) - 1)
        case "H", "f": moveTo(row: at(0) - 1, column: at(1) - 1)
        case "d": moveTo(row: at(0) - 1, column: column)
        case "I": for _ in 0..<at(0) { control("\t") }
        case "Z": moveTo(row: row, column: max(0, ((column - 1) / 8 - (at(0) - 1)) * 8))
        case "J": eraseInDisplay(at(0, 0))
        case "K": eraseInLine(at(0, 0))
        case "X": erase(row: row, from: column, to: min(Self.columns, column + at(0)))
        case "P": deleteCharacters(at(0))
        case "@": insertCharacters(at(0))
        case "L": insertLines(at(0))
        case "M": deleteLines(at(0))
        case "S": scrollUp(at(0))
        case "T": scrollDown(at(0))
        case "b": if let previous { for _ in 0..<min(at(0), Self.columns * Self.rows) { write(previous) } }
        case "r":
            let first = at(0) - 1
            let last = min(Self.rows, at(1, Self.rows)) - 1
            guard first < last else { return }
            top = first
            bottom = last
            moveTo(row: 0, column: 0)
        case "s": saveCursor()
        case "u": restoreCursor()
        case "m": selectGraphicRendition(groups)
        default: break
        }
    }

    private mutating func privateMode(_ modes: [Int], on: Bool) {
        for mode in modes {
            switch mode {
            case 7: autowrap = on
            case 47, 1047, 1049:
                if on, alternate == nil {
                    if mode == 1049 { saveCursor(); mainSaved = saved }
                    alternate = Self.blankScreen()
                    if mode == 1049 { moveTo(row: 0, column: 0) }
                } else if !on, alternate != nil {
                    alternate = nil
                    if mode == 1049 { saved = mainSaved; restoreCursor() }
                }
            default: break
            }
        }
    }

    private mutating func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            erase(row: cursor.row, from: cursor.column, to: Self.columns)
            for row in (cursor.row + 1)..<Self.rows { erase(row: row, from: 0, to: Self.columns) }
        case 1:
            for row in 0..<cursor.row { erase(row: row, from: 0, to: Self.columns) }
            erase(row: cursor.row, from: 0, to: cursor.column + 1)
        case 2, 3:
            for row in 0..<Self.rows { erase(row: row, from: 0, to: Self.columns) }
            if mode == 3 { scrollback = [] }
        default: break
        }
    }

    private mutating func eraseInLine(_ mode: Int) {
        switch mode {
        case 0: erase(row: cursor.row, from: cursor.column, to: Self.columns)
        case 1: erase(row: cursor.row, from: 0, to: cursor.column + 1)
        case 2: erase(row: cursor.row, from: 0, to: Self.columns)
        default: break
        }
    }

    private mutating func erase(row: Int, from: Int, to: Int) {
        guard from < to else { return }
        let blank = TerminalCell(text: " ", style: style.erased)
        for column in from..<to { rows[row][column] = blank }
        if from == 0, to == Self.columns { rows[row].isWrapped = false }
    }

    private mutating func deleteCharacters(_ count: Int) {
        let row = cursor.row
        let column = cursor.column
        let count = min(count, Self.columns - column)
        let blank = TerminalCell(text: " ", style: style.erased)
        do {
            rows[row].cells.removeSubrange(column..<(column + count))
            rows[row].cells.append(contentsOf: Array(repeating: blank, count: count))
        }
    }

    private mutating func insertCharacters(_ count: Int) {
        let row = cursor.row
        let column = cursor.column
        let count = min(count, Self.columns - column)
        let blank = TerminalCell(text: " ", style: style.erased)
        do {
            rows[row].cells.insert(contentsOf: Array(repeating: blank, count: count), at: column)
            rows[row].cells.removeLast(count)
        }
    }

    private mutating func insertLines(_ count: Int) {
        guard (top...bottom).contains(cursor.row) else { return }
        let start = top
        top = cursor.row
        scrollDown(count)
        top = start
        cursor.column = 0
    }

    private mutating func deleteLines(_ count: Int) {
        guard (top...bottom).contains(cursor.row) else { return }
        let start = top
        top = cursor.row
        let wasScrolled = scrolled
        scrollUpWithinRegion(count)
        scrolled = wasScrolled
        top = start
        cursor.column = 0
    }

    /// A scroll that never feeds the scrollback: deleting lines removes them.
    private mutating func scrollUpWithinRegion(_ count: Int) {
        let count = min(count, bottom - top + 1)
        let blank = blankLine()
        do {
            rows.removeSubrange(top..<(top + count))
            rows.insert(contentsOf: Array(repeating: blank, count: count), at: bottom - count + 1)
        }
    }

    private mutating func selectGraphicRendition(_ groups: [String]) {
        var codes: [[Int?]] = groups.map { $0.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) } }
        if codes.isEmpty { codes = [[0]] }
        var index = 0
        func next() -> Int? {
            index += 1
            return index < codes.count ? codes[index].first ?? nil : nil
        }
        /// 38 and 48 as `38;5;n` or `38;2;r;g;b`, or with colons in one group.
        func color(_ group: [Int?]) -> TerminalColor? {
            if group.count > 1 {
                let rest = Array(group.dropFirst())
                switch rest.first ?? nil {
                case 5: return rest.count > 1 ? (rest[1]).map { TerminalColor.indexed(UInt8(clamping: $0)) } : nil
                case 2:
                    let channels = rest.count >= 5 ? Array(rest[2...4]) : Array(rest.dropFirst().prefix(3))
                    guard channels.count == 3 else { return nil }
                    return .rgb(UInt8(clamping: channels[0] ?? 0), UInt8(clamping: channels[1] ?? 0), UInt8(clamping: channels[2] ?? 0))
                default: return nil
                }
            }
            switch next() {
            case 5: return next().map { TerminalColor.indexed(UInt8(clamping: $0)) }
            case 2:
                let r = next() ?? 0, g = next() ?? 0, b = next() ?? 0
                return .rgb(UInt8(clamping: r), UInt8(clamping: g), UInt8(clamping: b))
            default: return nil
            }
        }
        while index < codes.count {
            let group = codes[index]
            let code = (group.first ?? 0) ?? 0
            switch code {
            case 0: style = TerminalStyle()
            case 1: style.attributes.insert(.bold)
            case 2: style.attributes.insert(.dim)
            case 3: style.attributes.insert(.italic)
            case 4: if group.count > 1, group[1] == 0 { style.attributes.remove(.underline) } else { style.attributes.insert(.underline) }
            case 7: style.attributes.insert(.inverse)
            case 8: style.attributes.insert(.hidden)
            case 9: style.attributes.insert(.strikethrough)
            case 21: style.attributes.insert(.underline)
            case 22: style.attributes.subtract([.bold, .dim])
            case 23: style.attributes.remove(.italic)
            case 24: style.attributes.remove(.underline)
            case 27: style.attributes.remove(.inverse)
            case 28: style.attributes.remove(.hidden)
            case 29: style.attributes.remove(.strikethrough)
            case 30...37: style.foreground = .indexed(UInt8(code - 30))
            case 38: if let picked = color(group) { style.foreground = picked }
            case 39: style.foreground = .default
            case 40...47: style.background = .indexed(UInt8(code - 40))
            case 48: if let picked = color(group) { style.background = picked }
            case 49: style.background = .default
            case 90...97: style.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: style.background = .indexed(UInt8(code - 100 + 8))
            default: break
            }
            index += 1
        }
    }

    private static func blankScreen() -> [TerminalLine] {
        Array(repeating: TerminalLine(cells: Array(repeating: TerminalCell(text: " ", style: TerminalStyle()), count: columns)), count: rows)
    }

    /// DEC Special Graphics (`ESC ( 0`): the line drawing set.
    private static let lineDrawing: [Unicode.Scalar: Unicode.Scalar] = {
        let pairs: [(Character, Character)] = [
            ("`", "◆"), ("a", "▒"), ("f", "°"), ("g", "±"), ("j", "┘"), ("k", "┐"), ("l", "┌"), ("m", "└"), ("n", "┼"),
            ("o", "⎺"), ("p", "⎻"), ("q", "─"), ("r", "⎼"), ("s", "⎽"), ("t", "├"), ("u", "┤"), ("v", "┴"), ("w", "┬"),
            ("x", "│"), ("y", "≤"), ("z", "≥"), ("{", "π"), ("|", "≠"), ("}", "£"), ("~", "·"),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.unicodeScalars.first!, $0.1.unicodeScalars.first!) })
    }()
}

/// One row of cells, and whether it goes on from the row above: text that reached the last column
/// and wrapped here, as xterm's `isWrapped`, so its plain text joins that row's.
public struct TerminalLine: Hashable, Sendable, RandomAccessCollection, MutableCollection {
    public var cells: [TerminalCell]
    public var isWrapped = false

    public var startIndex: Int { cells.startIndex }
    public var endIndex: Int { cells.endIndex }

    public subscript(position: Int) -> TerminalCell {
        get { cells[position] }
        set { cells[position] = newValue }
    }
}

/// One cell: its text (a character with any marks joined to it), the style it was written in,
/// and whether it is the second half of a wide character.
public struct TerminalCell: Hashable, Sendable {
    public var text: String
    public var style: TerminalStyle
    public var width: Int
    public var isContinuation: Bool

    init(text: String, style: TerminalStyle, width: Int = 1, isContinuation: Bool = false) {
        self.text = text
        self.style = style
        self.width = width
        self.isContinuation = isContinuation
    }

    /// Something shows: text, or a ground other than the default.
    var isWritten: Bool {
        (!isContinuation && text != " " && !text.isEmpty) || style.background != .default || style.attributes.contains(.inverse)
    }
}

public struct TerminalStyle: Hashable, Sendable {
    public struct Attributes: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let bold = Attributes(rawValue: 1 << 0)
        public static let dim = Attributes(rawValue: 1 << 1)
        public static let italic = Attributes(rawValue: 1 << 2)
        public static let underline = Attributes(rawValue: 1 << 3)
        public static let inverse = Attributes(rawValue: 1 << 4)
        public static let hidden = Attributes(rawValue: 1 << 5)
        public static let strikethrough = Attributes(rawValue: 1 << 6)
    }

    public var foreground: TerminalColor = .default
    public var background: TerminalColor = .default
    public var attributes: Attributes = []

    public init(foreground: TerminalColor = .default, background: TerminalColor = .default, attributes: Attributes = []) {
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }

    /// What an erase leaves: the current ground, nothing else (xterm's background color erase).
    var erased: TerminalStyle { TerminalStyle(background: background) }
}

/// A cell's color: the theme's default, one of the 256 indexed colors (0–15 from the theme, as
/// apron-web's `terminalTheme`), or a true color.
public enum TerminalColor: Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)

    /// An indexed color past the theme's 16: xterm's 6×6×6 cube from 16, then 24 grays from 232.
    public static func xterm(_ index: UInt8) -> (UInt8, UInt8, UInt8)? {
        switch index {
        case 0..<16: return nil
        case 16..<232:
            let cube = Int(index) - 16
            let level = { (step: Int) -> UInt8 in step == 0 ? 0 : UInt8(55 + step * 40) }
            return (level(cube / 36), level(cube / 6 % 6), level(cube % 6))
        default:
            let gray = UInt8(8 + (Int(index) - 232) * 10)
            return (gray, gray, gray)
        }
    }
}

/// How many cells a character takes: 0 for marks, joiners and variation selectors, 2 for East
/// Asian wide and full-width characters and emoji, 1 for the rest.
public enum TerminalWidth {
    public static func of(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark: return 0
        case .format where value == 0x200D || value == 0x200B: return 0
        default: break
        }
        if (0xFE00...0xFE0F).contains(value) || (0xE0100...0xE01EF).contains(value) { return 0 }
        let wide: [ClosedRange<UInt32>] = [
            0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A, 0x23E9...0x23EC, 0x23F0...0x23F0, 0x23F3...0x23F3,
            0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653, 0x267F...0x267F, 0x2693...0x2693, 0x26A1...0x26A1,
            0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5, 0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA,
            0x26F2...0x26F3, 0x26F5...0x26F5, 0x26FA...0x26FA, 0x26FD...0x26FD, 0x2705...0x2705, 0x270A...0x270B,
            0x2728...0x2728, 0x274C...0x274C, 0x274E...0x274E, 0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797,
            0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C, 0x2B50...0x2B50, 0x2B55...0x2B55,
            0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF, 0xA960...0xA97F,
            0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
            0x16FE0...0x18AFF, 0x1B000...0x1B2FF, 0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x1F18E...0x1F18E,
            0x1F191...0x1F19A, 0x1F200...0x1F251, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB,
            0x1F90C...0x1F9FF, 0x1FA70...0x1FAFF, 0x20000...0x3FFFD,
        ]
        return wide.contains { $0.contains(value) } ? 2 : 1
    }
}
