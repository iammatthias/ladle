import Foundation
import Observation

/// The one toast a pane shows for what you asked of the server, as apron-web's `FeedbackState`
/// (#69): a request that takes longer than `quiet` says so ("Leaving…") until it is done, and one
/// that fails leaves its error until the next request or until it is dismissed.
@MainActor
@Observable
public final class RequestFeedback {
    public enum Kind: Hashable, Sendable {
        case pending
        case error
    }

    public struct Toast: Hashable, Sendable, Identifiable {
        public var kind: Kind
        public var text: String
        public var id: Int
    }

    /// How long a request may take before the toast admits it is still pending.
    public static let quiet: Duration = .milliseconds(600)

    public private(set) var current: Toast?
    @ObservationIgnored private var count = 0
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// Runs `operation`, saying `pending` once it has taken `quiet`, and its error (in the app's
    /// words) if it fails. A newer request takes the toast over.
    public func track(_ pending: String, _ operation: () async throws -> Void) async {
        count += 1
        let mine = count
        current = nil
        let timer = Task { [sleep] in
            try await sleep(Self.quiet)
            guard count == mine else { return }
            current = Toast(kind: .pending, text: pending, id: mine)
        }
        do {
            try await operation()
            timer.cancel()
            if count == mine { current = nil }
        } catch {
            timer.cancel()
            if count == mine { current = Toast(kind: .error, text: errorText(error), id: mine) }
        }
    }

    /// Clears `toast` if it is still the one shown: its ×, or one that no longer applies.
    public func dismiss(_ toast: Toast) {
        if current == toast { current = nil }
    }
}
