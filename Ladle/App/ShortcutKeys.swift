import ApronKit
import SwiftUI

/// `Shortcuts`, the one table of keys, turned into SwiftUI: the key commands a button takes
/// (`shortcut(_:)`), the chord a `KeyPress` is, and the Keyboard Shortcuts sheet.
extension Shortcuts.Chord {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let character): KeyEquivalent(character)
        case .up: .upArrow
        case .down: .downArrow
        case .left: .leftArrow
        case .right: .rightArrow
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .escape: .escape
        case .enter: .return
        }
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if self.modifiers.contains(.command) { modifiers.insert(.command) }
        if self.modifiers.contains(.option) { modifiers.insert(.option) }
        if self.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if self.modifiers.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    /// A key pressed on a focused view, or nil for one the table never binds.
    init?(_ press: KeyPress) {
        let key: Shortcuts.Key? = switch press.key {
        case .upArrow: .up
        case .downArrow: .down
        case .leftArrow: .left
        case .rightArrow: .right
        case .home: .home
        case .end: .end
        case .pageUp: .pageUp
        case .pageDown: .pageDown
        case .escape: .escape
        case .return: .enter
        default: press.characters.count == 1 ? press.characters.lowercased().first.map(Shortcuts.Key.character) : nil
        }
        guard let key else { return nil }
        var modifiers: Shortcuts.Modifiers = []
        if press.modifiers.contains(.command) { modifiers.insert(.command) }
        if press.modifiers.contains(.option) { modifiers.insert(.option) }
        if press.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if press.modifiers.contains(.control) { modifiers.insert(.control) }
        self.init(key, modifiers)
    }
}

extension View {
    /// The table's first key for `action`, as this button's key command, so the system's ⌘-hold
    /// list names it with the button's title.
    @ViewBuilder
    func shortcut(_ action: Shortcuts.Action) -> some View {
        if let chord = Shortcuts.all.flatMap(\.keys).first(where: { $0.action == action })?.chord {
            keyboardShortcut(chord.keyEquivalent, modifiers: chord.eventModifiers)
        } else {
            self
        }
    }
}

/// Key commands with no button on screen of their own (⌘/, ⌘K, Alt+↑ ↓): hidden buttons
/// titled as the table labels them, which the ⌘-hold list shows.
struct HiddenShortcuts: View {
    let actions: [Shortcuts.Action]
    let perform: (Shortcuts.Action) -> Void

    var body: some View {
        let bindings = Shortcuts.all.filter { $0.scope == .anywhere }.flatMap { entry in entry.keys.map { (entry.label, $0) } }
        ZStack {
            ForEach(Array(bindings.enumerated()), id: \.offset) { _, pair in
                let (label, binding) = pair
                if actions.contains(binding.action) {
                    Button(label) { perform(binding.action) }
                        .keyboardShortcut(binding.chord.keyEquivalent, modifiers: binding.chord.eventModifiers)
                }
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// apron-web's `?` dialog (#212, KeyboardShortcuts): the table's listed keys by group, each with
/// where it works and its keys as an iPad's keyboard marks them. ⌘/ or `?` on a message opens
/// it, and the room's ⋯ menu on iPad; holding ⌘ also shows the system's own list of key commands.
struct KeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Shortcuts.groups, id: \.group) { group in
                    Section {
                        ForEach(group.entries, id: \.self) { entry in row(entry).listRowBackground(Palette.raised) }
                    } header: {
                        Text(group.group.rawValue).formHeader()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.chrome)
            .navigationTitle("Keyboard Shortcuts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private func row(_ entry: Shortcuts.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.s3) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.label).apText(.ui).foregroundStyle(Palette.ink)
                if let place = entry.place { Text(place).apText(.sm).foregroundStyle(Palette.inkMuted) }
            }
            Spacer(minLength: Tokens.Space.s2)
            HStack(spacing: Tokens.Space.s2) {
                ForEach(Array(entry.chords.enumerated()), id: \.offset) { _, chord in
                    HStack(spacing: 2) {
                        ForEach(Array(chord.written.enumerated()), id: \.offset) { _, key in KeyCap(key) }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.label)
        .accessibilityValue(([entry.place].compactMap { $0 } + [entry.chords.map(\.spoken).joined(separator: ", or ")]).joined(separator: ", "))
    }
}

/// One key as the web's `<kbd>`: a small raised cap.
private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .apText(.sm, .medium)
            .monospacedDigit()
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Tokens.Space.s1 + 2)
            .frame(minWidth: 22, minHeight: 22)
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(Palette.lineStrong))
    }
}
