import Foundation

/// Select mode's moves and copy, as apron-web's `MessageSelection.move`, `moveToNewThread` and
/// `copySelectionLog` (#54, #95, #164, #168, #172).
extension ServerSession {
    /// Whether a message may be picked: one shown in the room, not deleted.
    public func maySelect(_ message: MessageSnapshot, in roomID: String) -> Bool {
        message.roomID == roomID && !message.isTombstone
    }

    /// Whether every picked message may move: checked before a new thread is made, which a
    /// refused move would leave empty.
    public func mayMoveAll(_ ids: [LogID]) -> Bool {
        !ids.isEmpty && ids.allSatisfy { store.message($0).map(mayMove) ?? false }
    }

    /// Where a selection in `roomID` may move: as one message's Move To offers.
    public func selectionDestinations(in roomID: String) -> [String] {
        let family = store.room(roomID)?.parentRoomID ?? roomID
        let threads = store.roomIDs.filter { store.room($0)?.parentRoomID == family }.sorted { codePointLess(title(of: $0), title(of: $1)) }
        return ([family] + threads).filter { $0 != roomID }
    }

    /// Moves the picked messages to `roomID`, all or nothing as far as permission goes: a message
    /// that isn't yours goes first, alone, and if the server refuses it nothing else is sent, so a
    /// conversation is never split between rooms. The rest go together; any refused stay picked
    /// (`selection.denied`). Moved into a thread, their authors not in it yet are added to it, so
    /// they still see their messages (apron-web #95), where this viewer may add people.
    public func move(_ selection: inout MessageSelection, to roomID: String) async -> SelectionMove {
        let ids = selection.ids
        let messages = ids.compactMap(store.message)
        guard !messages.isEmpty else { return SelectionMove(roomID: roomID, moved: false) }
        let probe = messages.first { !isYou($0.from.userID) }
        if let probe {
            do { try await move(probe, to: roomID) } catch {
                let reason = (error as? RPCError)?.message
                return SelectionMove(roomID: roomID, moved: false, problem: reason.map { "No messages were moved: \($0)" } ?? "No messages were moved")
            }
        }
        var refused: [LogID: String] = [:]
        for message in messages where message.messageID != probe?.messageID {
            do { try await move(message, to: roomID) } catch {
                refused[message.messageID] = (error as? RPCError)?.message ?? "Unable to move it"
            }
        }
        let movedMessages = messages.filter { refused[$0.messageID] == nil }
        let unadded = await addAuthors(of: movedMessages, from: selection.roomID, to: roomID)
        guard refused.isEmpty else {
            let failed = ids.filter { refused[$0] != nil }
            selection.keep(failed, of: ids.count)
            return SelectionMove(roomID: roomID, moved: false, problem: ids.compactMap { refused[$0] }.first, unadded: unadded)
        }
        return SelectionMove(roomID: roomID, moved: true, unadded: unadded)
    }

    /// New Thread from a selection: one thread under the pane's room, then the selection moves
    /// into it. Refused before anything is made when a picked message may not move.
    public func moveToNewThread(_ selection: inout MessageSelection, title: String, description: String) async -> SelectionMove {
        guard mayMoveAll(selection.ids) else { return SelectionMove(moved: false, problem: notMovableWords) }
        let parent = store.room(selection.roomID)?.parentRoomID ?? selection.roomID
        let thread: String
        do {
            guard let created = try await createRoom(title: title, description: description, parentRoomID: parent) else {
                return SelectionMove(moved: false, problem: "Invalid room response")
            }
            thread = created
        } catch {
            return SelectionMove(moved: false, problem: (error as? RPCError)?.message ?? (error as? LocalizedError)?.errorDescription ?? "No messages were moved")
        }
        var result = await move(&selection, to: thread)
        result.roomID = thread
        return result
    }

    /// Adds the authors of messages moved into a thread to it, once each, leaving out `~`
    /// identities, yourself and its members. Who may add whom is server policy, so a refusal
    /// changes nothing else: what comes back says how many weren't added and the first reason.
    private func addAuthors(of moved: [MessageSnapshot], from roomID: String, to target: String) async -> String? {
        guard store.room(target)?.parentRoomID != nil, !memberChangesUnsupported, mayAddMembers(to: roomID) else { return nil }
        let members = Set((store.members(of: target) ?? []).map { users.current($0.userID) })
        var authors: [String] = []
        for message in moved {
            let author = users.current(message.from.userID)
            if author.hasPrefix("~") || isYou(author) || members.contains(author) || authors.contains(author) { continue }
            authors.append(author)
        }
        let refused = await addMembers(authors, to: target)
        guard let first = refused.first else { return nil }
        let who = refused.count == authors.count ? (authors.count == 1 ? "the author" : "the authors") : "\(refused.count) of \(authors.count) authors"
        return "Moved, but \(who) couldn’t be added to the thread: \(first.message)"
    }

    /// The picked messages in timeline order as apron-web's Markdown log (`messageLog`): each
    /// sender's run quoted under their name and time, what a reply answers, reactions, and how
    /// many messages a gap leaves out.
    public func markdownLog(of ids: [LogID], in roomID: String, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
        let order = timeline(roomID).map(\.messageID)
        let picked = Set(ids)
        let messages = timeline(roomID).filter { picked.contains($0.messageID) }
        let options = MessageLog.Options(
            nameOf: { [users] in users.plainName(for: $0.from) },
            lookup: { [store] in store.message($0) },
            now: now,
            reactions: { [store, users] message in
                store.reactions(on: message.messageID)?.map { summary in
                    let names = summary.userIDs.map { users.plainName(for: users.user($0).flatMap(UserObject.init) ?? UserObject(["user_id": .string($0)])!) }
                    return MessageLog.Reaction(emoji: summary.emoji, names: names, count: summary.userIDs.count)
                }
            },
            order: order,
            calendar: calendar
        )
        return MessageLog.markdown(messages, options: options)
    }
}
