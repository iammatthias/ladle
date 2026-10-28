import Foundation
import Observation

/// Every saved server and its session. Each server has its own sign-in and one identity; the
/// sessions share nothing but the token store.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var records: [ServerRecord] = []
    public private(set) var sessions: [UUID: ServerSession] = [:]
    /// The last error saving `servers.json`, for the UI to show.
    public private(set) var saveError: String?

    private let serverStore: ServerStore?
    private let tokens: any TokenStore
    private let environment: ServerSession.Environment

    /// `serverStore` nil keeps the list in memory only.
    public init(serverStore: ServerStore?, tokens: any TokenStore, environment: ServerSession.Environment = .live) {
        self.serverStore = serverStore
        self.tokens = tokens
        self.environment = environment
    }

    /// Loads the saved servers and starts a session for each.
    public func load() throws {
        guard let serverStore else { return }
        for record in try serverStore.load() where sessions[record.id] == nil {
            records.append(record)
            startSession(for: record)
        }
    }

    public func session(for id: UUID) -> ServerSession? { sessions[id] }

    @discardableResult
    public func add(_ record: ServerRecord) -> ServerSession {
        if let existing = sessions[record.id] { return existing }
        records.append(record)
        save()
        return startSession(for: record)
    }

    /// Saves an edited record; its session reconnects when the address or origin changed.
    public func update(_ record: ServerRecord) async {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index] = record
        save()
        await sessions[record.id]?.update(record)
    }

    /// Stops the session and forgets the server and its token.
    public func remove(_ id: UUID) async {
        await sessions.removeValue(forKey: id)?.stop()
        records.removeAll { $0.id == id }
        try? tokens.setToken(nil, for: id)
        save()
    }

    @discardableResult
    private func startSession(for record: ServerRecord) -> ServerSession {
        let session = ServerSession(record: record, tokens: tokens, environment: environment)
        session.onRecordChange = { [weak self] changed in self?.accountChanged(changed) }
        sessions[record.id] = session
        session.start()
        return session
    }

    private func accountChanged(_ record: ServerRecord) {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[index].account = record.account
        save()
    }

    private func save() {
        guard let serverStore else { return }
        do {
            try serverStore.save(records)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
