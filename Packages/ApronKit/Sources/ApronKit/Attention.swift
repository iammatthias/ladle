import Foundation
import Observation

/// Whether anyone is attending the app (§4.5 `idle`), as apron-web's `PagePresence` decides it
/// for a handheld: no input for `idleAfter` (5 minutes, as Discord and Teams wait), or the app in
/// the background, makes it idle; any input ends that at once and starts the wait again.
/// `SessionStore` hands each change to every session, which tells its server.
@MainActor
@Observable
public final class Attention {
    /// Nobody is attending.
    public private(set) var idle = false
    /// When someone last used the app, so an idle report can say how long ago; nil before any use.
    public private(set) var inputAt: Date?

    /// Called with `idle` and `inputAt` on each change of `idle`.
    @ObservationIgnored var onChange: ((Bool, Date?) -> Void)?
    @ObservationIgnored private var timer: Task<Void, Never>?
    private let idleAfter: Duration
    private let now: @Sendable () -> Date

    /// Input closer together than this does not restart the wait: touches come many a second.
    static let throttle: TimeInterval = 1

    public init(idleAfter: Duration = .seconds(300), now: @escaping @Sendable () -> Date = { Date() }) {
        self.idleAfter = idleAfter
        self.now = now
    }

    /// Someone used the app: a touch, or typing. It ends `idle` at once and restarts the wait.
    public func input() {
        let time = now()
        if !idle, let inputAt, time.timeIntervalSince(inputAt) < Self.throttle { return }
        inputAt = time
        set(idle: false)
        timer?.cancel()
        timer = Task { [weak self, idleAfter] in
            try? await Task.sleep(for: idleAfter)
            guard !Task.isCancelled else { return }
            self?.set(idle: true)
        }
    }

    /// The app went to the background: on a handheld nobody is attending it.
    public func background() {
        timer?.cancel()
        timer = nil
        set(idle: true)
    }

    private func set(idle: Bool) {
        guard self.idle != idle else { return }
        self.idle = idle
        onChange?(idle, inputAt)
    }
}
