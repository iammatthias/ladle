import Foundation

/// The live text `PreviewFixtures` serves, as apron-web's `live-demos.ts` plays it: a test run in
/// a terminal with what a terminal has to get right (16, 256 and true colors, a progress bar
/// redrawn with carriage returns, box drawing, lines rewritten by moving the cursor, and escapes
/// that must do nothing: a title, the clipboard, a link, the bell), and a Markdown reply that
/// revises itself (a placeholder a form feed clears, a typo backspaces correct), cut off inside
/// a code fence while it is still being written.
extension PreviewFixtures {
    public static let liveTerminalURL = URL(string: "https://home.example/live/ramp")!
    public static let liveAppendURL = URL(string: "https://home.example/live/plan")!
    /// The live text `/live` types, read back as the composer holds it.
    public static let liveTypingURL = URL(string: "https://home.example/live/typing")!
    public static let liveTypingText = "Rolled back 0042. Renewing the runner’s cert now, then I’ll re-run the dep"

    /// The Load test thread's live terminal and live reply.
    public static let liveTerminalMessageID = message(-139)
    public static let finishedTerminalMessageID = message(-142)
    public static let liveAppendMessageID = message(-138)
    public static let waitingTerminalMessageID = message(-137)
    public static let waitingAppendMessageID = message(-136)

    /// Answers the two live texts at once and then holds them open, so they stay live.
    static let readLiveText: LiveTextRead = { url in
        AsyncThrowingStream { continuation in
            let text: String? = switch url {
            case liveTerminalURL: terminalDemo
            case liveAppendURL: appendDemo
            case liveTypingURL: liveTypingText
            default: nil
            }
            guard let text else {
                continuation.finish(throwing: LiveTextRefused(status: 404))
                return
            }
            continuation.yield(.started)
            // Cut every 7 bytes, characters included, as a network would.
            let bytes = Array(text.utf8)
            for start in stride(from: 0, to: bytes.count, by: 7) {
                continuation.yield(.bytes(Data(bytes[start..<min(start + 7, bytes.count)])))
            }
        }
    }

    /// A write that takes everything typed and never answers, so `/live` stays live.
    static let writeLiveText: LiveTextWrite = { _, body in
        for await _ in body {}
        return LiveTextWriteResponse(status: 200)
    }

    private static let esc = "\u{1B}"
    private static let reset = "\u{1B}[0m"
    private static func sgr(_ codes: String) -> String { "\(esc)[\(codes)m" }

    private static func cells(_ text: String) -> Int {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression).unicodeScalars.count
    }

    private static func box(_ left: String, _ right: String) -> String {
        let line = String(repeating: "─", count: 78)
        let gap = String(repeating: " ", count: 76 - cells(left) - cells(right))
        return "\(sgr("2"))┌\(line)┐\(reset)\r\n\(sgr("2"))│\(reset) \(left)\(gap)\(right) \(sgr("2"))│\(reset)\r\n\(sgr("2"))└\(line)┘\(reset)\r\n"
    }

    private static let packages = [("store", "0.41s", "42"), ("protocol", "1.07s", "61"), ("http", "0.63s", "25")]

    private static func bar(_ percent: Int) -> String {
        let filled = Int((Double(percent) / 5).rounded())
        let number = String(percent)
        return "\r  coverage \(sgr("36"))\(String(repeating: "█", count: filled))\(sgr("2"))\(String(repeating: "░", count: 20 - filled))\(reset) \(String(repeating: " ", count: 3 - number.count))\(number)%"
    }

    private static let terminalDemo: String = {
        let hues = [196, 202, 208, 214, 220, 226, 190, 154, 118, 82, 46, 47, 48, 49, 50, 51, 45, 39, 33, 27, 21, 57, 93, 129, 165, 201, 200, 199, 198, 197]
        let cube = hues.map { "\(sgr("48;5;\($0)"))  " }.joined() + reset
        let ramp = (0..<60).map { i -> String in
            let t = Double(i) / 59
            let channel = { (from: Double, to: Double) in Int((from + (to - from) * t).rounded()) }
            return "\(sgr("48;2;\(channel(0x8F, 0xF2));\(channel(0xB0, 0x8A));\(channel(0xF5, 0x3C))")) "
        }.joined() + reset
        var out = "\(esc)]0;make test\u{07}\(esc)]52;c;aGVsbG8gZnJvbSB0aGUgdGVybWluYWw=\u{07}\u{07}\(sgr("1"))$ make ramp\(reset)\r\n"
        out += box("\(sgr("1"))apron\(reset) load ramp", "\(sgr("2"))80×40 · ANSI demo\(reset)")
        out += packages.map { "  \(sgr("33"))…\(reset) \($0.0.padding(toLength: 10, withPad: " ", startingAt: 0)) \(sgr("2"))running\(reset)\r\n" }.joined()
        for (index, package) in packages.enumerated() {
            let up = packages.count - index
            out += "\(esc)[\(up)A\r\(esc)[2K  \(sgr("32"))✓\(reset) \(package.0.padding(toLength: 10, withPad: " ", startingAt: 0)) \(sgr("32"))ok\(reset)  \(package.2) tests  \(sgr("2"))\(package.1)\(reset)\(esc)[\(up)B\r"
        }
        for percent in [0, 10, 25, 40, 55, 70, 85, 100] { out += bar(percent) }
        out += "\r\n\r\n"
        out += "  16 colors  " + (30...37).map { "\(sgr(String($0)))██" }.joined() + (90...97).map { "\(sgr(String($0)))██" }.joined() + "\(reset)\r\n"
        out += "  256 colors \(cube)\r\n"
        out += "  true color \(ramp)\r\n"
        out += "  \(sgr("1"))bold\(reset) \(sgr("2"))dim\(reset) \(sgr("3"))italic\(reset) \(sgr("4"))underline\(reset) \(sgr("7"))inverse\(reset) \(sgr("9"))struck\(reset)  \(esc)]8;;https://example.com/report\(esc)\\a link that opens nothing\(esc)]8;;\(esc)\\\r\n\r\n"
        out += "\(sgr("1;32"))PASS\(reset) 3 packages, 128 tests, 0 failures \(sgr("2"))in 2.11s\(reset)\r\n"
        out += "\(sgr("2"))ramping to 500 connections…\(reset)"
        return out
    }()

    private static let appendDemo = [
        "_Looking at the deploy logs…_", "\u{0C}",
        "Here is the plan for the rollback, step by step:\n\n",
        "1. **Roll back** the `orders_idx` migration with `./migrate down 0042`.\n",
        "2. Renew the runner’s cert — it expired at 02:00 UTC, so every deploy since then faield",
        "\u{08}\u{08}\u{08}led.\n",
        "3. Re-run the deploy, and watch the p99 latency on the dashboard.\n\n",
        "```sh\n./migrate down 0042\nkubectl rollout",
    ].joined()
}
