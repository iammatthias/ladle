/// Preferences' sections, in the order apron-web's nav lists them (`PREFERENCE_SECTIONS`, #184).
/// Each can be opened directly, as apron-web's `preferencesOpener.open(section)` does: the
/// profile bar opens Profile, a "notifications are off" notice opens Notifications.
///
/// apron-web also names the open section in its page's fragment (`#room=general&preferences=media`).
/// That is apron-web's own page address, not a link.apron.chat key, and no client writes it in a
/// link, so `ApronLink` keeps refusing a link that names nothing but `preferences`, and keeps the
/// key unread beside a place. Ladle opens sections from its own screens.
public enum PreferencesSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case profile, notifications, appearance, media, history

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .profile: "Profile"
        case .notifications: "Notifications"
        case .appearance: "Appearance"
        case .media: "Media"
        case .history: "History"
        }
    }

    /// An SF Symbol for the section's row.
    public var symbol: String {
        switch self {
        case .profile: "person.crop.circle"
        case .notifications: "bell"
        case .appearance: "paintbrush"
        case .media: "photo.on.rectangle"
        case .history: "clock.arrow.circlepath"
        }
    }
}
