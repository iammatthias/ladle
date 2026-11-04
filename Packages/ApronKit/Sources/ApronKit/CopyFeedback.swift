/// A copy button's Copied state, as apron-web's CopyButton (#207): a copy that worked shows
/// Copied for `shown`, and one that failed (nothing to copy) stops an earlier one saying it.
public struct CopyFeedback: Equatable, Sendable {
    public static let shown: Duration = .milliseconds(1500)

    public private(set) var copied = false
    /// Counts copies, so a view's wait restarts with each (`task(id:)`).
    public private(set) var generation = 0

    public init() {}

    public mutating func finish(_ done: Bool) {
        generation += 1
        copied = done
    }

    /// `shown` has passed since the last copy.
    public mutating func expire() {
        copied = false
    }
}
