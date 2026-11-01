/// apron-web's mention ping (`MentionTracker`): a message that mentions you pulses once as it
/// arrives, or when an edit adds you, and never for what the room held when it was shown. A
/// timeline keeps one per room it shows and feeds it every change.
public struct MentionPulse: Sendable {
    /// How long a message stays pulsing; the ring itself runs once.
    public static let held: Duration = .milliseconds(1200)

    private struct Seen: Sendable {
        var logID: LogID
        var mentioned: Bool
    }

    private var shown = false
    private var watermark: LogID?
    private var seen: [LogID: Seen] = [:]

    public init() {}

    /// The messages that start pulsing. The first call is the room as shown: its newest log
    /// position, `latest` or its newest snapshot's, becomes the watermark, and nothing pulses.
    /// After it, a message pulses when it mentions `you` (not your own), its snapshot is logged
    /// past the watermark, and it did not already mention you.
    public mutating func arrivals(in messages: [MessageSnapshot], latest: LogID?, you: String?) -> [LogID] {
        let first = !shown
        if first {
            shown = true
            watermark = ([latest] + messages.map(\.logID)).compactMap { $0 }.max()
        }
        var arrived: [LogID] = []
        for message in messages {
            let before = seen[message.messageID]
            if before?.logID == message.logID { continue }
            let mentioned = you.map { message.mentions($0) && message.from.userID != $0 } ?? false
            seen[message.messageID] = Seen(logID: message.logID, mentioned: mentioned)
            guard !first, mentioned, before?.mentioned != true else { continue }
            if let watermark, message.logID <= watermark { continue }
            arrived.append(message.messageID)
        }
        return arrived
    }
}
