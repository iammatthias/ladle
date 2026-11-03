import Foundation

/// What a day pill says, as apron-web's `dayLabelOf`: "Today", "Yesterday", else the short
/// weekday, day and month, with the year when it is not `now`'s.
public enum DayLabel {
    public static func text(_ date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated)
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }
}

/// apron-web's FloatingDay: while the timeline scrolls back, the day of the messages at its top
/// floats there, and fades `shownFor` after the scrolling stops.
public enum FloatingDay {
    public static let shownFor: Duration = .milliseconds(1200)

    /// The day of the first message among the items in view, nil when that day's own pill shows
    /// above it, since the pill already says it, or when no message is in view.
    public static func day(of items: [TimelineItem], visible: Set<String>) -> Date? {
        for item in items where visible.contains(item.id) {
            switch item {
            case .day: return nil
            case .message(let message, _, _): return message.date
            default: continue
            }
        }
        return nil
    }
}
