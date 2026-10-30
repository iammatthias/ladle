import ApronKit
import SwiftUI

/// The accent on a message with a reminder: when it is due ("Due in 1 hr", then "Due now"),
/// kept current each half minute, and a button that clears it.
struct ReminderBadge: View {
    let due: Date
    let clear: () -> Void

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: Tokens.Space.s2) {
                Label(Reminder.label(due: due, now: context.date), systemImage: "alarm")
                    .apText(.sm, .semibold)
                    .foregroundStyle(Palette.accent)
                    .labelStyle(TightLabel())
                Spacer(minLength: 0)
                Button("Clear Reminder", systemImage: "xmark", action: clear)
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .foregroundStyle(Palette.inkMuted)
                    .buttonStyle(.plain)
                    .touchTarget()
                    .padding(.vertical, -(Tokens.Size.touchTarget - Tokens.Size.chipH) / 2)
            }
        }
    }
}

/// Remind Me's Custom…: a date and time from now on, then Set.
struct ReminderDateSheet: View {
    @Binding var date: Date
    let set: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            DatePicker("Remind Me", selection: $date, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.graphical)
                .tint(Palette.accent)
                .padding(.horizontal, Tokens.Space.s4)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Palette.chrome)
                .navigationTitle("Remind Me")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                    ToolbarItem(placement: .confirmationAction) { Button("Set", action: set) }
                }
        }
        .presentationDetents([.large])
        .presentationBackground(Palette.chrome)
    }
}
