import Foundation

extension ServerSession {
    /// How far back a room opening at its New line pages to reach it, as apron-web's
    /// `DIVIDER_PAGES`: a room read long ago opens at its latest rather than loading its backlog.
    public static let dividerPages = 3
    /// How long the timeline waits for the New line to show before it scrolls, as apron-web's
    /// `JUMP_WAIT_MS`.
    public static let dividerWait: Duration = .seconds(4)

    /// The message a visit opens at, as apron-web's `landAtDivider`: with `after` where you had
    /// read, pages back at most `dividerPages` while the oldest loaded message is newer than it,
    /// then gives the message the New line goes before (`newLine`). Nil keeps the room at its
    /// latest: nothing unread, the line still out of reach, or `still` false (a link, a jump or a
    /// scroll moved the timeline first), which is checked before each page and at the end.
    public func landAtDivider(_ roomID: String, after: LogID?, still: () -> Bool = { true }) async -> LogID? {
        guard let after else { return nil }
        var pages = 0
        let clock = ContinuousClock()
        let deadline = clock.now + Self.dividerWait
        while pages < Self.dividerPages, still(), canLoadOlder(roomID),
              let oldest = store.messages(in: roomID).first?.messageID, oldest > after {
            if histories[roomID]?.isLoading == true {
                // The timeline's own paging row is loading a page; that one counts.
                guard clock.now < deadline, (try? await Task.sleep(for: .milliseconds(50))) != nil else { break }
                continue
            }
            do { try await loadOlder(roomID) } catch { break }
            pages += 1
        }
        guard still() else { return nil }
        return newLine(in: roomID, after: after)
    }
}
