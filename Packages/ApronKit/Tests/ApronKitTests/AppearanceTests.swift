@testable import ApronKit
import Foundation
import XCTest

@MainActor
final class AppearanceTests: XCTestCase {
    func testDefaultsToTheSystemModeAndApron() {
        XCTAssertEqual(AppearancePreferences(saved: nil), AppearancePreferences(mode: .system, theme: "apron", customCSS: ""))
        XCTAssertEqual(AppearancePreferences.default.css, PremadeTheme.all[0].css)
    }

    /// apron-web's appearance.test.ts, "keeps only supported modes and themes".
    func testKeepsOnlySupportedModesAndThemes() throws {
        XCTAssertEqual(AppearancePreferences(saved: try JSONValue(parsing: #"{"mode":"dark","theme":"ferrous","customCss":"--accent: red;"}"#)),
                       AppearancePreferences(mode: .dark, theme: "ferrous", customCSS: "--accent: red;"))
        XCTAssertEqual(AppearancePreferences(saved: try JSONValue(parsing: #"{"mode":"sepia","theme":"neon","customCss":7}"#)), .default)
        let long = String(repeating: "x", count: 4001)
        XCTAssertEqual(AppearancePreferences(saved: ["theme": "custom", "customCss": .string(long)]),
                       AppearancePreferences(mode: .system, theme: "custom", customCSS: ""))
        XCTAssertEqual(AppearancePreferences(mode: .system, theme: "custom", customCSS: "--accent: red;").css, "--accent: red;")
    }

    func testCustomStartsFromTheThemeChosenBeforeTheFirstTime() {
        let ferrous = AppearancePreferences(mode: .dark, theme: "ferrous")
        let custom = ferrous.choosing("custom")
        XCTAssertEqual(custom, AppearancePreferences(mode: .dark, theme: "custom", customCSS: PremadeTheme.all[1].css))
        let edited = AppearancePreferences(mode: .dark, theme: "gumball", customCSS: "--accent: red;")
        XCTAssertEqual(edited.choosing("custom").customCSS, "--accent: red;")
        XCTAssertEqual(edited.choosing("linocut"), AppearancePreferences(mode: .dark, theme: "linocut", customCSS: "--accent: red;"))
        XCTAssertEqual(edited.choosing("neon"), edited)
    }

    func testKeepsTheChoiceOnThisDevice() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AppearanceSettings(directory: directory)
        XCTAssertEqual(settings.shown, PremadeTheme.resolved["apron"])
        settings.update(AppearancePreferences(mode: .light, theme: "custom", customCSS: "--accent: #123456;"))
        XCTAssertEqual(settings.shown.color("--accent").light, RGBA(0x123456))

        let reopened = AppearanceSettings(directory: directory)
        XCTAssertEqual(reopened.current, AppearancePreferences(mode: .light, theme: "custom", customCSS: "--accent: #123456;"))
        XCTAssertEqual(reopened.shown.color("--focus").dark, RGBA(0x123456))
        let saved = try JSONValue(parsing: Data(contentsOf: directory.appending(path: "appearance.json")))
        XCTAssertEqual(saved, ["mode": "light", "theme": "custom", "customCss": "--accent: #123456;"])
    }

    func testPreviewsEditsThatReadAndRevertsToWhatIsSaved() {
        let settings = AppearanceSettings()
        settings.update(AppearancePreferences(theme: "gumball"))
        XCTAssertNil(settings.preview("--accent: #00ff00;"))
        XCTAssertEqual(settings.shown.color("--accent").dark, RGBA(0x00ff00))
        XCTAssertEqual(settings.current.theme, "gumball")
        XCTAssertEqual(settings.preview("--accent: url(x);"), "--accent can’t use url(), @, braces, backslashes or !important.")
        XCTAssertEqual(settings.shown.color("--accent").dark, RGBA(0x00ff00))
        settings.revert()
        XCTAssertEqual(settings.shown, PremadeTheme.resolved["gumball"])
    }

    func testASavedCustomThemeWithAnErrorSetsNothing() {
        let settings = AppearanceSettings()
        settings.update(AppearancePreferences(theme: "custom", customCSS: "body { color: red; }"))
        XCTAssertEqual(settings.shown.color("--accent"), ResolvedTheme.apron.color("--accent"))
    }

    func testEditsShowWhileTheyReadAndApplyKeepsThem() {
        let settings = AppearanceSettings()
        let editor = ThemeEditor(settings: settings)
        editor.choose("custom")
        XCTAssertEqual(editor.draft, PremadeTheme.all[0].css, "Custom starts from Apron, the theme chosen before")
        XCTAssertFalse(editor.edited)

        editor.edit("--accent: #00ff00;")
        XCTAssertTrue(editor.edited)
        XCTAssertEqual(editor.draftError, "")
        XCTAssertEqual(settings.shown.color("--accent").dark, RGBA(0x00ff00))
        editor.edit("--accent: #00ff00; nope")
        XCTAssertEqual(editor.draftError, "Expected a token such as --font-sans: value; at “nope”.")
        XCTAssertEqual(settings.shown.color("--accent").dark, RGBA(0x00ff00), "the last that read stays on show")
        XCTAssertFalse(editor.apply())
        XCTAssertEqual(editor.themeError, "Expected a token such as --font-sans: value; at “nope”.")
        XCTAssertEqual(settings.current.customCSS, PremadeTheme.all[0].css)

        editor.edit("--accent: #0000ff;")
        editor.setMode(.dark)
        XCTAssertEqual(settings.current.mode, .dark)
        XCTAssertEqual(settings.shown.color("--accent").dark, RGBA(0x0000ff), "the edit stays on show in the new mode")
        XCTAssertTrue(editor.apply())
        XCTAssertEqual(settings.current, AppearancePreferences(mode: .dark, theme: "custom", customCSS: "--accent: #0000ff;"))
        XCTAssertFalse(editor.edited)

        editor.edit("--accent: #ff0000;")
        editor.close()
        XCTAssertEqual(editor.draft, "--accent: #0000ff;")
        XCTAssertEqual(settings.shown.color("--accent").dark, RGBA(0x0000ff))

        editor.edit(String(repeating: " ", count: 4100))
        XCTAssertEqual(editor.draft.utf16.count, 4000)

        let broken = ThemeEditor(settings: AppearanceSettings())
        broken.settings.update(AppearancePreferences(theme: "apron", customCSS: "body { color: red; }"))
        broken.choose("custom")
        XCTAssertEqual(broken.themeError, "Expected a token such as --font-sans: value; at “body { color: red”.")
    }

    func testBaseColorsWriteTheSameCSS() {
        let bases = ThemeBases(ground: Themed(RGBA(0x101010), RGBA(0xfafafa)), ink: Themed(RGBA(0xeeeeee), RGBA(0x111111)),
                               accent: Themed(RGBA(0xff8800), RGBA(0xff8800)), link: Themed(RGBA(0x88aaff, 0.5), RGBA(0x2244aa)))
        let apron = bases.written(into: PremadeTheme.all[0].css)
        XCTAssertTrue(apron.hasPrefix(":root {\n\t/* Interface */\n\t--font-sans: var(--font-sans-system);"))
        XCTAssertTrue(apron.contains("\t--base-ground: light-dark(#f8f6f3, #15151f);"), "the commented example stays as it was")
        XCTAssertTrue(apron.hasSuffix("""
        Any other token in tokens.css can be set too, such as --line-strong. */
        \t--base-ground: light-dark(#fafafa, #101010);
        \t--base-ink: light-dark(#111111, #eeeeee);
        \t--base-accent: #ff8800;
        \t--base-link: light-dark(#2244aa, #88aaff);
        }

        """))
        let parsed = ThemeCSS.parse(apron)
        XCTAssertNil(parsed.error)
        XCTAssertEqual(ResolvedTheme(vars: parsed.vars).color("--bg-100"), Themed(RGBA(0x101010), RGBA(0xfafafa)))

        let again = ThemeBases(ResolvedTheme(vars: parsed.vars)).written(into: apron)
        XCTAssertEqual(again, apron, "writing the bases a theme shows changes nothing")
        XCTAssertEqual(bases.written(into: "--line: red;\n--base-ink: #000;"), """
        --line: red;
        \t--base-ground: light-dark(#fafafa, #101010);
        \t--base-ink: light-dark(#111111, #eeeeee);
        \t--base-accent: #ff8800;
        \t--base-link: light-dark(#2244aa, #88aaff);

        """)
    }
}
