import Observation

/// One sign-in link used at a time, as apron-web's `SignInLinks` task (#209): a link signing in
/// or adding to this account while another is under way does nothing, so two fresh connections
/// never race, and a link asked about meanwhile waits to be shown until the first ends.
@MainActor @Observable
public final class LinkWork {
    public private(set) var isBusy = false

    public init() {}

    /// Runs `work` unless a link is already being used. False when it did not start.
    @discardableResult
    public func run(_ work: @escaping @MainActor () async -> Void) -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        Task {
            await work()
            isBusy = false
        }
        return true
    }
}
