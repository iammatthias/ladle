@testable import ApronKit
import Foundation
import XCTest

/// apron-web's own `parseThemeCss` output (tools/design/theme-goldens.py).
private struct Goldens: Decodable {
    struct Theme: Decodable {
        let id: String
        let name: String
        let vars: [[String]]
    }

    struct Case: Decodable {
        let css: String
        let vars: [[String]]
        let error: String?
    }

    let themes: [Theme]
    let cases: [Case]

    static func load() throws -> Goldens {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "apron-web", withExtension: "json", subdirectory: "Fixtures/themes"))
        return try JSONDecoder().decode(Goldens.self, from: Data(contentsOf: url))
    }
}

private func pairs(_ vars: [ThemeVar]) -> [[String]] { vars.map { [$0.name, $0.value] } }

private func hex(_ color: Themed<RGBA>) -> [String] { [color.light.description, color.dark.description] }

final class ThemeCSSTests: XCTestCase {
    func testParsesEveryCaseAsApronWebDoes() throws {
        let goldens = try Goldens.load()
        XCTAssertEqual(goldens.cases.count, 32)
        for golden in goldens.cases {
            let parsed = ThemeCSS.parse(golden.css)
            XCTAssertEqual(parsed.error, golden.error, golden.css)
            XCTAssertEqual(pairs(parsed.vars), golden.vars, golden.css)
        }
    }

    func testPremadeThemesAreApronWebsInItsOrder() throws {
        let goldens = try Goldens.load()
        XCTAssertEqual(PremadeTheme.all.map(\.id), ["apron", "ferrous", "gumball", "linocut"])
        XCTAssertEqual(PremadeTheme.all.map(\.name), ["Apron", "Ferrous", "Gumball", "Linocut (high contrast)"])
        for (theme, golden) in zip(PremadeTheme.all, goldens.themes) {
            XCTAssertEqual(theme.id, golden.id)
            XCTAssertEqual(pairs(ThemeCSS.parse(theme.css).vars), golden.vars, theme.id)
        }
    }

    func testErrorsReadAsApronWebWritesThem() {
        XCTAssertEqual(ThemeCSS.parse("nope here is a long declaration without any colon in it at all").error,
                       "Expected a token such as --font-sans: value; at “nope here is a long declaration without …”.")
        XCTAssertEqual(ThemeCSS.parse("--a: x !important;").error, "--a can’t use url(), @, braces, backslashes or !important.")
        XCTAssertEqual(ThemeCSS.parse("--base-ground: red; --base-ink: #fff;").error,
                       "--base-ground takes a #hex color, or light-dark(#hex, #hex).")
        XCTAssertEqual(ThemeCSS.parse("--base-accent: #abc;").error, "Base colors start from --base-ground and --base-ink together.")
        XCTAssertEqual(ThemeCSS.parse(String(repeating: "x", count: 4001)).error, "A theme can be at most 4000 characters.")
        XCTAssertNil(ThemeCSS.parse(String(repeating: " ", count: 4000)).error)
    }

    func testReadsABaseAsOneHexOrALightDarkPair() {
        XCTAssertEqual(ThemeCSS.readBase("#abc").map(hex), ["#aabbcc", "#aabbcc"])
        XCTAssertEqual(ThemeCSS.readBase("light-dark(#ffffff, #000000)").map(hex), ["#ffffff", "#000000"])
        XCTAssertNil(ThemeCSS.readBase("red"))
        XCTAssertNil(ThemeCSS.readBase("light-dark(#fff, var(--x))"))
    }

    func testReadsAValueAsOneModeShowsIt() {
        XCTAssertEqual(ThemeCSS.forMode("light-dark(#fff0f6, #2a1426)", .light), "#fff0f6")
        XCTAssertEqual(ThemeCSS.forMode(" light-dark(#fff0f6, #2a1426) ", .dark), "#2a1426")
        XCTAssertEqual(ThemeCSS.forMode("light-dark(rgb(1, 2, 3), rgb(4, 5, 6))", .dark), "rgb(4, 5, 6)")
        XCTAssertEqual(ThemeCSS.forMode("#123456", .dark), "#123456")
    }
}

final class ResolvedThemeTests: XCTestCase {
    private func theme(_ id: String) -> ResolvedTheme {
        ResolvedTheme(css: PremadeTheme.all.first { $0.id == id }!.css)
    }

    func testApronIsTokensCSSAsTuned() {
        let apron = ResolvedTheme.apron
        XCTAssertEqual(hex(apron.color("--accent")), ["#a83c14", "#f28a3c"])
        XCTAssertEqual(hex(apron.color("--bg-100")), ["#f8f6f3", "#15151f"])
        XCTAssertEqual(hex(apron.color("--focus")), ["#a83c14", "#f28a3c"])
        XCTAssertEqual(hex(apron.color("--selected")), ["#1c1f33 0.08", "#ece9e4 0.08"])
        XCTAssertEqual(hex(apron.color("--presence-idle")), ["#b26f00", "#d6b24c"])
        XCTAssertEqual(hex(apron.color("--scrim")), ["#05050c 0.68", "#05050c 0.68"])
        XCTAssertEqual(apron.shadow("--shadow-popover").light, ShadowToken(y: 8, blur: 24, color: RGBA(0x1c1f33, 0.12)))
        XCTAssertEqual(apron.number("--space-2"), 8)
        XCTAssertEqual(apron.number("--duration-fast"), 0.12)
        XCTAssertEqual(apron.number("--opacity-disabled"), 0.5)
        XCTAssertEqual(apron.fraction("--count-shade"), Themed(0.55, 0.82))
        XCTAssertEqual(apron.curve("--ease-slide"), Curve(0.2, 0, 0, 1))
        XCTAssertEqual(ResolvedTheme(css: PremadeTheme.all[0].css).values, apron.values)
    }

    func testEveryAppliedTokenReadsInEveryTheme() {
        let applied = WebTokens.applied.filter { !$0.hasPrefix("--font-") }
        XCTAssertEqual(Set(ResolvedTheme.kinds.keys), applied)
        for premade in PremadeTheme.all {
            let resolved = ResolvedTheme(css: premade.css)
            XCTAssertEqual(Set(resolved.values.keys), applied, premade.id)
            XCTAssertEqual(resolved.notShown, [], premade.id)
        }
    }

    func testFerrousDerivesItsPaletteFromItsBases() {
        let ferrous = theme("ferrous")
        let expected: [String: [String]] = [
            "--bg-rail": ["#dad7d1", "#171717"], "--bg-000": ["#e6e3dc", "#1f1f1f"], "--bg-100": ["#f2efe8", "#292929"],
            "--bg-200": ["#ebe8e1", "#333333"], "--bg-300": ["#e0ddd7", "#3e3d3c"], "--line": ["#e0ddd7", "#3a3a39"],
            "--line-strong": ["#84827d", "#807e79"], "--ink": ["#2a2926", "#d7d3c8"], "--ink-muted": ["#666460", "#a3a098"],
            "--accent": ["#2a2926", "#f0e9d8"], "--on-accent": ["#f2efe8", "#292929"], "--accent-soft": ["#d2cfc9", "#4d4c49"],
            "--denim": ["#3f5468", "#a9b6c4"], "--denim-soft": ["#d9d9d6", "#434548"],
        ]
        for (name, colors) in expected { XCTAssertEqual(hex(ferrous.color(name)), colors, name) }
    }

    func testGumballKeepsWhatItSetsOverWhatItsBasesGive() {
        let gumball = theme("gumball")
        let expected: [String: [String]] = [
            "--bg-100": ["#fff6fb", "#251a35"], "--ink": ["#3a2e5c", "#f3eaff"], "--accent": ["#c93a7e", "#ff8cc6"],
            "--on-accent": ["#fff6fb", "#251a35"], "--denim": ["#2f6fd6", "#8fc4ff"], "--bg-rail": ["#ddd6f2", "#141a36"],
            "--bg-000": ["#ebe6fb", "#1a2142"], "--bg-200": ["#ffffff", "#2f2242"], "--bg-300": ["#ffe3f0", "#3b2b52"],
            "--line": ["#f0dbe8", "#3e3058"], "--line-strong": ["#9a7a94", "#8e7fae"], "--ink-muted": ["#6f638f", "#b9abd8"],
            "--accent-soft": ["#ffd9ec", "#4b2a52"], "--denim-soft": ["#dcebff", "#24345c"],
        ]
        for (name, colors) in expected { XCTAssertEqual(hex(gumball.color(name)), colors, name) }
    }

    func testLinocutIsFirmerThanItsBases() {
        let linocut = theme("linocut")
        let expected: [String: [String]] = [
            "--bg-rail": ["#e0e0e0", "#000000"], "--bg-000": ["#f0f0f0", "#000000"], "--bg-100": ["#ffffff", "#000000"],
            "--bg-200": ["#f6f6f6", "#0f0f0f"], "--bg-300": ["#e8e8e8", "#1f1f1f"], "--ink": ["#000000", "#ffffff"],
            "--accent": ["#8a2c08", "#ff9a4d"], "--on-accent": ["#ffffff", "#000000"], "--accent-soft": ["#ecddd7", "#2e1c0e"],
            "--denim": ["#1b3a8f", "#b3cbff"], "--denim-soft": ["#dfe3ef", "#242933"], "--ink-muted": ["#33353f", "#d6d4de"],
            "--line": ["#8f8a82", "#5c5c6e"], "--line-strong": ["#3d3a35", "#c8c8d4"],
        ]
        for (name, colors) in expected { XCTAssertEqual(hex(linocut.color(name)), colors, name) }
    }

    func testAliasesFollowTheTheme() {
        let gumball = theme("gumball")
        XCTAssertEqual(hex(gumball.color("--focus")), ["#c93a7e", "#ff8cc6"])
        XCTAssertEqual(hex(gumball.color("--hover")), ["#ffe3f0", "#3b2b52"])
        XCTAssertEqual(hex(gumball.color("--hover-soft")), ["#ffffff", "#2f2242"])
        XCTAssertEqual(hex(gumball.color("--chosen")), ["#fff6fb", "#251a35"])
        XCTAssertEqual(hex(gumball.color("--selected")), ["#3a2e5c 0.08", "#f3eaff 0.08"])
        XCTAssertEqual(hex(gumball.color("--presence-unknown")), ["#6f638f", "#b9abd8"])
        // What no premade theme touches keeps tokens.css's values.
        XCTAssertEqual(hex(gumball.color("--danger")), ["#b0173f", "#ff6f86"])
        XCTAssertEqual(hex(gumball.color("--presence-idle")), ["#b26f00", "#d6b24c"])
        XCTAssertEqual(hex(gumball.color("--private")), ["#8b3199", "#d99be8"])
    }

    /// apron-web's theme-colors.test.ts: readable text, links, accents and borders, light and dark.
    func testEveryPremadeThemeReads() {
        for premade in PremadeTheme.all {
            let t = ResolvedTheme(css: premade.css)
            for mode in ColorMode.allCases {
                let ground = t.color("--bg-100")[mode]
                for ink in ["--ink", "--ink-muted", "--denim", "--accent"] {
                    XCTAssertGreaterThanOrEqual(t.color(ink)[mode].contrast(with: ground), 4.5, "\(premade.id) \(ink) \(mode)")
                }
                XCTAssertGreaterThanOrEqual(t.color("--on-accent")[mode].contrast(with: t.color("--accent")[mode]), 4.5, premade.id)
                for name in ["--bg-100", "--bg-200"] {
                    XCTAssertGreaterThanOrEqual(t.color("--line-strong")[mode].contrast(with: t.color(name)[mode]), 3, "\(premade.id) \(name) \(mode)")
                }
            }
        }
    }

    func testACustomThemeSetsAnyColorSyntaxAndKeepsWhatItCantUse() {
        let custom = ResolvedTheme(css: """
        :root {
          --accent: rgb(10 20 30 / 50%);
          --denim: hsl(120, 100%, 25%);
          --ink: rebeccapurple;
          --line: color-mix(in srgb, var(--accent) 50%, white);
          --danger: var(--nope, #123);
          --ok: oklch(62.8% 0.2577 29.23);
          --warn: light-dark(#111111, var(--ink));
          --space-2: 10px;
          --duration-fast: 0.3s;
          --z-menu: 9;
          --made-up: 1;
          --bg-100: wat;
          --radius-sm: 1em;
        }
        """)
        XCTAssertEqual(hex(custom.color("--accent")), ["#0a141e 0.5", "#0a141e 0.5"])
        XCTAssertEqual(hex(custom.color("--focus")), ["#0a141e 0.5", "#0a141e 0.5"])
        XCTAssertEqual(hex(custom.color("--denim")), ["#008000", "#008000"])
        XCTAssertEqual(hex(custom.color("--ink")), ["#663399", "#663399"])
        XCTAssertEqual(hex(custom.color("--line")), ["#adb1b4 0.75", "#adb1b4 0.75"])
        XCTAssertEqual(hex(custom.color("--danger")), ["#112233", "#112233"])
        XCTAssertEqual(hex(custom.color("--ok")), ["#ff0000", "#ff0000"])
        XCTAssertEqual(hex(custom.color("--warn")), ["#111111", "#663399"])
        XCTAssertEqual(custom.number("--space-2"), 10)
        XCTAssertEqual(custom.number("--duration-fast"), 0.3)
        // What it can't read keeps tokens.css's value, and is listed.
        XCTAssertEqual(hex(custom.color("--bg-100")), ["#f8f6f3", "#15151f"])
        XCTAssertEqual(custom.number("--radius-sm"), 6)
        XCTAssertEqual(custom.notShown.map(\.name), ["--z-menu", "--made-up", "--bg-100", "--radius-sm"])
    }

    func testCycleAndMissingVarsKeepTheDefault() {
        let custom = ResolvedTheme(css: "--accent: var(--denim); --denim: var(--accent); --ink: var(--nope);")
        XCTAssertEqual(hex(custom.color("--accent")), ["#a83c14", "#f28a3c"])
        XCTAssertEqual(hex(custom.color("--ink")), ["#1c1f33", "#ece9e4"])
        XCTAssertEqual(custom.notShown.map(\.name), ["--accent", "--denim", "--ink"])
    }

    func testNamedColorsAreCSSs() {
        XCTAssertEqual(CSSValue.namedColors.count, 148)
        XCTAssertEqual(CSSValue.color("CornflowerBlue", mode: .dark), RGBA(0x6495ed))
        XCTAssertEqual(CSSValue.color("transparent", mode: .dark), RGBA(0, 0))
        XCTAssertEqual(CSSValue.color("#11223344", mode: .dark), RGBA(0x112233, Double(0x44) / 255))
        XCTAssertNil(CSSValue.color("#12345", mode: .dark))
    }
}
