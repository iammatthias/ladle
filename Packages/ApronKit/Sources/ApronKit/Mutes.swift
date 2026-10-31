import Foundation

/// When a mute ends (§4.5 `mute`), as apron-web's `PausedUntil`: at a time, or not until it is
/// changed. A pause is your unscoped mute; a room's mute covers its threads.
public enum MuteEnd: Hashable, Sendable {
    case at(Date)
    case untilChanged

    /// A `mute` from the server: `true`, or seconds left from `now`. Nil for `false`, `0`, or a
    /// value that is not a `mute` (a negative number, a string).
    public init?(wire: JSONValue?, now: Date) {
        switch wire {
        case .bool(true): self = .untilChanged
        case .number:
            guard let seconds = wire?.doubleValue, seconds.isFinite, seconds > 0 else { return nil }
            self = .at(now.addingTimeInterval(seconds))
        default: return nil
        }
    }

    /// Whether `value` is a `mute` at all (§4.5): a boolean, or seconds at least 0.
    static func isMute(_ value: JSONValue?) -> Bool {
        switch value {
        case .bool: true
        case .number: (value?.doubleValue).map { $0.isFinite && $0 >= 0 } ?? false
        default: false
        }
    }

    /// The `mute` to send: `true`, or the whole seconds left, at least 1 (apron-web's `muteFor`).
    public func wire(now: Date) -> JSONValue {
        switch self {
        case .untilChanged: .bool(true)
        case .at(let date): .number(String(max(1, Int(date.timeIntervalSince(now).rounded(.up)))))
        }
    }

    public func isActive(at now: Date) -> Bool {
        switch self {
        case .untilChanged: true
        case .at(let date): date > now
        }
    }

    /// When it ends, in words, as apron-web's `pausedUntilLabel`: "until 14:30", "until tomorrow
    /// 9:00", "until Fri 9:00", or `open` ("until you resume", "until you unmute").
    public func words(now: Date, calendar: Calendar = .current, locale: Locale = .current, open: String = "until you resume") -> String {
        guard case .at(let date) = self else { return open }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        let clock = MuteChoice.clock(date, calendar: calendar, locale: locale)
        if days <= 0 { return "until \(clock)" }
        if days == 1 { return "until tomorrow \(clock)" }
        var weekday = Date.FormatStyle(locale: locale, calendar: calendar).weekday(.abbreviated)
        weekday.timeZone = calendar.timeZone
        return "until \(date.formatted(weekday)) \(clock)"
    }
}

/// A way to pause or mute, as a menu lists it: its title, when it would end in words, and its end.
public struct MuteChoice: Hashable, Sendable, Identifiable {
    public var title: String
    /// When it would end, such as "until 15:42"; nil for one that lasts until changed.
    public var hint: String?
    public var end: MuteEnd
    public var id: String { title }

    /// The hour Until tomorrow ends at.
    static let morningHour = 9

    /// Pause notifications, as apron-web's `pauseChoices`: an hour, eight hours, until the next
    /// 9:00 (this morning before 9:00, else tomorrow), or until resumed.
    public static func pause(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> [MuteChoice] {
        let today = calendar.component(.hour, from: now) < morningHour
        let day = today ? now : calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: day) ?? day
        return [
            after(hours: 1, now: now, calendar: calendar, locale: locale),
            after(hours: 8, now: now, calendar: calendar, locale: locale),
            MuteChoice(title: today ? "Until this morning" : "Until tomorrow", hint: clock(morning, calendar: calendar, locale: locale), end: .at(morning)),
            MuteChoice(title: "Until I resume", hint: nil, end: .untilChanged),
        ]
    }

    /// Mute a room or thread, as apron-web's `roomMuteChoices`: an hour, two, eight, or until unmuted.
    public static func room(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> [MuteChoice] {
        [1, 2, 8].map { after(hours: $0, now: now, calendar: calendar, locale: locale) }
            + [MuteChoice(title: "Until I unmute", hint: nil, end: .untilChanged)]
    }

    private static func after(hours: Int, now: Date, calendar: Calendar, locale: Locale) -> MuteChoice {
        let end = now.addingTimeInterval(TimeInterval(hours * 3600))
        return MuteChoice(title: "For \(hours) \(hours == 1 ? "hour" : "hours")", hint: "until \(clock(end, calendar: calendar, locale: locale))", end: .at(end))
    }

    static func clock(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

/// Whether a room or thread is muted (§4.5 `mute` with its `room_id`), and by whose mute: a
/// room's covers its threads, as apron-web's `mutedWithRoom`.
public enum RoomMute: Hashable, Sendable {
    /// Its own mute.
    case own(MuteEnd)
    /// A thread silenced by its room's mute: Unmute unmutes that room.
    case withRoom(String, MuteEnd)

    public var isWithRoom: Bool {
        if case .withRoom = self { true } else { false }
    }

    public var end: MuteEnd {
        switch self {
        case .own(let end), .withRoom(_, let end): end
        }
    }
}
