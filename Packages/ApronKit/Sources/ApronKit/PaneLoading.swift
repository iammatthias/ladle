import Foundation
import Observation

/// A flag for an indicator of something usually quick, as apron-web's `SettleFlag`: on only once
/// its source has stayed on for `showAfter`, then on for at least `minShown`, and for `linger`
/// after the source last went off. Quick work shows nothing; slow work, also in steps, never
/// flickers. Time is passed in, so it runs on any clock.
public struct SettleFlag: Hashable, Sendable {
    public static let showAfter: TimeInterval = 0.4
    public static let minShown: TimeInterval = 0.6
    public static let linger: TimeInterval = 0.3

    public private(set) var isOn = false
    private var shownAt: Date?
    private var showAt: Date?
    private var hideAt: Date?

    public init() {}

    /// When `isOn` changes by itself if the source stays as it is.
    public var nextChange: Date? { showAt ?? hideAt }

    public mutating func set(_ source: Bool, at now: Date) {
        advance(to: now)
        if source {
            hideAt = nil
            if !isOn, showAt == nil { showAt = now.addingTimeInterval(Self.showAfter) }
        } else {
            showAt = nil
            if isOn, hideAt == nil, let shownAt {
                hideAt = now.addingTimeInterval(max(Self.linger, Self.minShown - now.timeIntervalSince(shownAt)))
            }
        }
    }

    public mutating func advance(to now: Date) {
        if let showAt, now >= showAt {
            isOn = true
            shownAt = showAt
            self.showAt = nil
        }
        if let hideAt, now >= hideAt {
            isOn = false
            self.hideAt = nil
        }
    }
}

/// What a room's timeline says while it catches up, as apron-web's page does it (behavior.md,
/// "Checking for new messages"): one floating pill for the way back from a short drop,
/// "Reconnecting…" and then "Checking for new messages…"; a thin line under the header while
/// other rooms catch up and this one is current, never with the pill; and "Loading earlier
/// messages…" at the top while older messages load. Each is a `SettleFlag`, and nothing shows in
/// the first `quiet` seconds of a way back, so a quick reconnect shows nothing at all.
public struct PaneLoading: Hashable, Sendable {
    /// apron-web's `RECONNECT_QUIET_MS`.
    public static let quiet: TimeInterval = 1.5

    public struct Input: Hashable, Sendable {
        /// A short drop's way back, before signing in again (`ServerSession.reconnectingQuietly`).
        public var reconnecting = false
        /// This room's catch-up after a reconnect has not finished.
        public var paneCatchingUp = false
        /// Another room's catch-up has not finished.
        public var othersCatchingUp = false
        public var loadingOlder = false
        public var isThread = false

        public init(reconnecting: Bool = false, paneCatchingUp: Bool = false, othersCatchingUp: Bool = false,
                    loadingOlder: Bool = false, isThread: Bool = false) {
            (self.reconnecting, self.paneCatchingUp, self.othersCatchingUp, self.loadingOlder, self.isThread) =
                (reconnecting, paneCatchingUp, othersCatchingUp, loadingOlder, isThread)
        }
    }

    public struct Shown: Hashable, Sendable {
        /// The floating pill over the foot of the timeline.
        public var pill: String?
        /// The thin line under the header.
        public var catchingUpLine = false
        /// The pill at the top of the timeline.
        public var older: String?

        public init(pill: String? = nil, catchingUpLine: Bool = false, older: String? = nil) {
            (self.pill, self.catchingUpLine, self.older) = (pill, catchingUpLine, older)
        }
    }

    private var checking = SettleFlag()
    private var updating = SettleFlag()
    private var olderFlag = SettleFlag()
    private var input = Input()
    /// When the latest way back began, which starts its quiet moments.
    private var wayBackSince: Date?
    private var quietEnds: Date?
    private var pillWords = ""
    private var olderWords = ""
    public private(set) var shown = Shown()

    public init() {}

    /// When `shown` changes by itself if the input stays as it is: `advance(to:)` then.
    public var nextChange: Date? {
        [quietEnds, checking.nextChange, updating.nextChange, olderFlag.nextChange].compactMap(\.self).min()
    }

    /// Takes the input as of `now`. Changes due before then happen first at their own times, so
    /// a late call shows what a timely one would have.
    public mutating func update(_ input: Input, at now: Date) {
        while let due = nextChange, due <= now { step(self.input, at: due) }
        step(input, at: now)
    }

    private mutating func step(_ input: Input, at now: Date) {
        if input.reconnecting, !self.input.reconnecting { wayBackSince = now }
        self.input = input
        let ends = wayBackSince?.addingTimeInterval(Self.quiet)
        let quiet = ends.map { now < $0 } ?? false
        quietEnds = quiet ? ends : nil
        let source = !quiet && (input.paneCatchingUp || input.reconnecting)
        checking.set(source, at: now)
        updating.set(!quiet && !input.paneCatchingUp && !checking.isOn && input.othersCatchingUp, at: now)
        olderFlag.set(input.loadingOlder, at: now)
        // The words follow the work while it goes on, and stay as they were while the pill lingers.
        if source { pillWords = input.reconnecting ? "Reconnecting…" : input.isThread ? "Checking for new replies…" : "Checking for new messages…" }
        if input.loadingOlder { olderWords = input.isThread ? "Loading earlier replies…" : "Loading earlier messages…" }
        shown = Shown(pill: checking.isOn ? pillWords : nil, catchingUpLine: updating.isOn && !checking.isOn,
                      older: olderFlag.isOn ? olderWords : nil)
    }

    public mutating func advance(to now: Date) { update(input, at: now) }
}

extension ServerSession {
    /// A short drop's way back: signed in before, not yet again, and not a problem the room view
    /// shows a banner for (`ConnectionState.isProblem`). The page stays as it was meanwhile.
    public var reconnectingQuietly: Bool {
        guard you != nil else { return false }
        switch status {
        case .reconnecting, .connecting, .signingIn: return ConnectionState(status)?.isProblem == false
        default: return false
        }
    }

    /// Whether a room opened before is still catching up after signing in again (§4.3.5): its
    /// catch-up pages it forward from its checkpoint and marks it live once done.
    public func isCatchingUp(_ roomID: String) -> Bool {
        guard status == .signedIn, let history = histories[roomID] else { return false }
        return history.checkpoint != nil && !history.isLive
    }

    func paneLoadingInput(_ roomID: String) -> PaneLoading.Input {
        PaneLoading.Input(reconnecting: reconnectingQuietly, paneCatchingUp: isCatchingUp(roomID),
                          othersCatchingUp: histories.keys.contains { $0 != roomID && isCatchingUp($0) },
                          loadingOlder: histories[roomID]?.isLoading == true,
                          isThread: store.room(roomID)?.parentRoomID != nil)
    }

    /// Your dot in the profile bar, as apron-web's ProfileBar: your status once signed in; until
    /// then a dashed ring (`unknown`), never online's green. Nil without a status.
    public var ownPresence: Presence? {
        guard let presence = Presence(status: chosenStatus) else { return nil }
        return status == .signedIn ? presence : .unknown
    }

    /// What your dot says while it is the dashed ring: the connection's state in words.
    public var ownPresenceWords: String? {
        guard status != .signedIn, ownPresence != nil else { return nil }
        return ConnectionState(status)?.title(record)
    }
}

/// Runs a room's `PaneLoading` on the session's clock (`Environment.now` and `sleep`): it takes
/// the session's state each time it changes, and wakes when a flag is due to change by itself.
@MainActor
@Observable
public final class PaneLoadingWatch {
    public private(set) var shown = PaneLoading.Shown()
    @ObservationIgnored private var loading = PaneLoading()
    @ObservationIgnored private let session: ServerSession
    @ObservationIgnored public let roomID: String

    public init(session: ServerSession, roomID: String) {
        self.session = session
        self.roomID = roomID
    }

    /// Follows the session until its task is cancelled.
    public func run() async {
        let sleep = session.environment.sleep
        while !Task.isCancelled {
            let (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let input = withObservationTracking { session.paneLoadingInput(roomID) } onChange: { changed.yield() }
            let now = session.environment.now()
            loading.update(input, at: now)
            if shown != loading.shown { shown = loading.shown }
            let wait = loading.nextChange.map { max(0, $0.timeIntervalSince(now)) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { for await _ in changes { return } }
                if let wait { group.addTask { try? await sleep(.seconds(wait)) } }
                await group.next()
                group.cancelAll()
            }
        }
    }
}
