import Foundation

/// What a hardware keyboard does where apron-web binds a key (PARITY section 25), worked out here
/// so the views only pass the key on.
public enum KeyboardCommands {
    /// `x` on a focused message, as apron-web's Message `keydown`: in select mode it picks or
    /// unpicks the message (nil once nothing is left picked, which ends select mode); otherwise
    /// it starts select mode with the message.
    public static func pressX(on id: LogID, selection: MessageSelection?, roomID: String, order: [LogID]) -> MessageSelection? {
        guard var selection else { return MessageSelection(roomID: roomID, first: id) }
        return selection.toggle(id, order: order) ? selection : nil
    }

    /// ← and → in the media viewer, as apron-web's MediaViewer `step`: the item `by` places from
    /// `id`, or nil past either end, where the viewer stays.
    public static func step(_ items: [MediaItem], from id: String, by: Int) -> String? {
        guard let index = items.firstIndex(where: { $0.id == id }), items.indices.contains(index + by) else { return nil }
        return items[index + by].id
    }
}
