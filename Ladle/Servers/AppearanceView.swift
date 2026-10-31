import ApronKit
import SwiftUI
import UIKit

/// Preferences > Appearance, as apron-web's: the mode over any theme, and a premade theme or
/// Custom, each with a swatch in its own colors and face. Custom opens its CSS (`ThemeCSSView`).
struct AppearanceView: View {
    let editor: ThemeEditor

    var body: some View {
        let settings = editor.settings
        Form {
            Section {
                Picker("Mode", selection: Binding(get: { settings.current.mode }, set: editor.setMode)) {
                    Text("System").tag(ThemeMode.system)
                    Text("Light").tag(ThemeMode.light)
                    Text("Dark").tag(ThemeMode.dark)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Palette.raised)
            } header: {
                Text("Mode")
            } footer: {
                Text("System follows your device's light or dark setting.")
            }

            Section {
                ForEach(PremadeTheme.all) { theme in
                    themeRow(id: theme.id, name: theme.name, preview: PremadeTheme.resolved[theme.id] ?? .apron)
                }
                themeRow(id: AppearancePreferences.custom, name: "Custom", preview: customPreview)
                if settings.current.theme == AppearancePreferences.custom {
                    NavigationLink {
                        ThemeCSSView(editor: editor)
                    } label: {
                        Label("Theme CSS", systemImage: "curlybraces").apText(.body).foregroundStyle(Palette.ink)
                    }
                    .listRowBackground(Palette.raised)
                    if !editor.themeError.isEmpty {
                        Text(editor.themeError).apText(.sm).foregroundStyle(Palette.danger).listRowBackground(Palette.raised)
                    }
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Fonts and other design tokens, over either mode. The first time, Custom starts from the theme you had. Ferrous is set in Recursive and Gumball in Nunito, both under the SIL Open Font License 1.1.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.chrome)
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var customPreview: ResolvedTheme {
        let current = editor.settings.current
        return ResolvedTheme(css: current.customCSS.isEmpty ? current.css : current.customCSS)
    }

    private func themeRow(id: String, name: String, preview: ResolvedTheme) -> some View {
        let chosen = editor.settings.current.theme == id
        return Button { editor.choose(id) } label: {
            HStack(spacing: Tokens.Space.s3) {
                ThemeSwatch(theme: preview)
                Text(name).apText(.body).foregroundStyle(Palette.ink)
                Spacer()
                if chosen { Image(systemName: "checkmark").foregroundStyle(Palette.accent).fontWeight(.semibold) }
            }
            .touchTarget()
        }
        .listRowBackground(Palette.raised)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The custom theme's CSS, the same text as apron-web's Theme CSS field: it shows as it is typed
/// while it reads, Apply keeps it, and what Ladle doesn't use is listed under it. Colors… writes
/// the four base colors from color pickers.
struct ThemeCSSView: View {
    let editor: ThemeEditor
    @State private var choosingColors = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                TextEditor(text: Binding(get: { editor.draft }, set: editor.edit))
                    .apText(.ui, mono: true)
                    .foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .frame(minHeight: 300)
                    .accessibilityLabel("Theme CSS")
                    .listRowBackground(Palette.raised)
            } footer: {
                Text("Edits show as you type; Apply keeps them. Only `--token: value;` declarations are read, colors can be `light-dark(light, dark)`, and nothing loads with `url()`. A theme from apron-web's Preferences pastes in as it is.")
            }
            if !editor.themeError.isEmpty || !editor.draftError.isEmpty || !unused.isEmpty {
                Section {
                    if !editor.themeError.isEmpty {
                        Text(editor.themeError).apText(.sm).foregroundStyle(Palette.danger)
                    } else if !editor.draftError.isEmpty {
                        Text("Not showing yet: \(editor.draftError)").apText(.sm).foregroundStyle(Palette.inkMuted)
                    }
                    if !unused.isEmpty {
                        Text("Kept, but not used on iOS: \(unused.joined(separator: ", "))").apText(.sm).foregroundStyle(Palette.inkMuted)
                    }
                }
                .listRowBackground(Palette.raised)
            }
            Section {
                Button("Colors…", systemImage: "paintpalette") { choosingColors = true }
                Button("Discard Changes", role: .destructive, action: editor.discard).disabled(!editor.edited)
            }
            .listRowBackground(Palette.raised)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.chrome)
        .navigationTitle("Theme CSS")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Apply") {
                    if editor.apply() {
                        focused = false
                    } else {
                        UIAccessibility.post(notification: .announcement, argument: editor.themeError)
                    }
                }
                .disabled(!editor.edited)
            }
        }
        .sheet(isPresented: $choosingColors) {
            BaseColorsView(bases: ThemeBases(editor.settings.shown)) { bases in editor.edit(bases.written(into: editor.draft)) }
        }
    }

    /// What the theme on show sets that Ladle has no use for, or can't read.
    private var unused: [String] { editor.settings.shown.notShown.map(\.name) }
}

/// A theme at a glance, in the mode on screen: its ground, ink, accent and link.
struct ThemeSwatch: View {
    let theme: ResolvedTheme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let mode: ColorMode = scheme == .light ? .light : .dark
        let color = { (name: String) in Color(uiColor: theme.color(name)[mode].uiColor) }
        HStack(spacing: 3) {
            Text("Aa").font(BundledFonts.font(theme.fonts.sans, size: 13, weight: .semibold, mono: false).font).foregroundStyle(color("--ink"))
            Circle().fill(color("--accent")).frame(width: 8, height: 8)
            Capsule().fill(color("--denim")).frame(width: 10, height: 3)
        }
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background(color("--bg-100"), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(color("--line-strong"), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// Colors…: the four base colors (`--base-ground`, `--base-ink`, `--base-accent`, `--base-link`),
/// light and dark, from color pickers, for typing hex on a phone is slow. Done writes them into
/// the theme's CSS, which derives the rest of the palette from them, as apron-web's does.
struct BaseColorsView: View {
    @State var bases: ThemeBases
    let done: (ThemeBases) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                row("Ground", \.ground, "The timeline's ground; the others step from it.")
                row("Ink", \.ink, "Text.")
                row("Accent", \.accent, "What you can do: buttons, Send, a mention of you.")
                row("Link", \.link, "Where you can go: links, threads, the New line.")
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("Base Colors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        done(bases)
                        dismiss()
                    }
                }
            }
        }
    }

    private func row(_ title: String, _ key: WritableKeyPath<ThemeBases, Themed<RGBA>>, _ note: String) -> some View {
        Section {
            ColorPicker("Light", selection: binding(key, .light), supportsOpacity: false)
            ColorPicker("Dark", selection: binding(key, .dark), supportsOpacity: false)
        } header: {
            Text(title)
        } footer: {
            Text(note)
        }
        .listRowBackground(Palette.raised)
    }

    private func binding(_ key: WritableKeyPath<ThemeBases, Themed<RGBA>>, _ mode: ColorMode) -> Binding<Color> {
        Binding {
            Color(uiColor: bases[keyPath: key][mode].uiColor)
        } set: { color in
            var (r, g, b, a) = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
            UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: mode == .light ? .light : .dark))
                .getRed(&r, green: &g, blue: &b, alpha: &a)
            func byte(_ c: CGFloat) -> UInt32 { UInt32(max(0, min(255, (c * 255).rounded()))) }
            let picked = RGBA(byte(r) << 16 | byte(g) << 8 | byte(b))
            let old = bases[keyPath: key]
            bases[keyPath: key] = mode == .light ? Themed(old.dark, picked) : Themed(picked, old.light)
        }
    }
}
