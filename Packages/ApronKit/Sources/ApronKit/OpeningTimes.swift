import Foundation

/// How long a new connection may take to open and bring the server's `server` frame (§3.1)
/// before it is dropped as if it had failed, as apron-web's `OPENING_MS` (#216): a handshake sent
/// into a network that went away otherwise waits out URLSession's 60 s request timeout, with
/// "Still trying to reconnect…" up and nothing else tried.
public struct OpeningTimes: Sendable, Equatable {
    public var wait: Duration
    /// The wait while a connection was dropped for staying quiet less than `patientFor` ago, so a
    /// slow network isn't met with one new connection after another (`PROBE_PATIENT_MS`).
    public var patient: Duration
    public var patientFor: Duration

    public init(wait: Duration = .seconds(10), patient: Duration = .seconds(30), patientFor: Duration = .seconds(180)) {
        self.wait = wait
        self.patient = patient
        self.patientFor = patientFor
    }

    /// The wait for the next opening, given how long ago a connection was last dropped for
    /// staying quiet (an opening that ran out, or a socket silent for two ping intervals).
    public func wait(sinceQuietDrop elapsed: Duration?) -> Duration {
        guard let elapsed, elapsed < patientFor else { return wait }
        return patient
    }
}
