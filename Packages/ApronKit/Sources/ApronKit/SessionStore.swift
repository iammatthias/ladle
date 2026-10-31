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
    /// Reminders about messages on every server, kept beside `servers.json`.
    public let reminders: Reminders
    /// Where media loads from, on every server, kept beside `servers.json`.
    public let mediaSettings: MediaSettings
    /// Every room's composer draft, kept beside `servers.json`, its files in `Staged`.
    public let drafts: Drafts
    /// Whether anyone attends the app, which every session tells its server (§4.5 `idle`).
    public let attention: Attention

    private let serverStore: ServerStore?
    private let tokens: any TokenStore
    private let positions: any ReadPositionStore
    private let environment: ServerSession.Environment

    /// `serverStore` nil keeps the list, the read positions, the reminders and the drafts in memory
    /// only. A kept store sweeps staged files no draft holds.
    public init(serverStore: ServerStore?, tokens: any TokenStore, environment: ServerSession.Environment = .live,
                notifier: any ReminderNotifier = SilentReminderNotifier()) {
        self.serverStore = serverStore
        self.tokens = tokens
        positions = serverStore.map { FileReadPositionStore(directory: $0.directory) } ?? InMemoryReadPositionStore()
        reminders = Reminders(store: serverStore.map { FileReminderStore(directory: $0.directory) } ?? InMemoryReminderStore(),
                              notifier: notifier)
        mediaSettings = MediaSettings(directory: serverStore?.directory)
        if let directory = serverStore?.directory {
            drafts = Drafts(store: FileDraftStore(directory: directory), staging: directory.appending(path: "Staged", directoryHint: .isDirectory))
            drafts.pruneStaging()
        } else {
            drafts = Drafts()
        }
        self.environment = environment
        attention = Attention(now: environment.now)
        attention.onChange = { [weak self] idle, inputAt in
            guard let self else { return }
            for session in sessions.values { session.setIdle(idle, inputAt: inputAt) }
        }
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

    /// Stops the session and forgets the server, its token, its reminders and its drafts.
    public func remove(_ id: UUID) async {
        await sessions.removeValue(forKey: id)?.stop()
        await reminders.removeAll(server: id)
        drafts.removeAll(server: id)
        records.removeAll { $0.id == id }
        try? tokens.setToken(nil, for: id)
        save()
    }

    @discardableResult
    private func startSession(for record: ServerRecord) -> ServerSession {
        let session = ServerSession(record: record, tokens: tokens, positions: positions, mediaSettings: mediaSettings, environment: environment)
        session.onRecordChange = { [weak self] changed in self?.accountChanged(changed) }
        session.onInput = { [weak self] in self?.attention.input() }
        if attention.idle { session.setIdle(true, inputAt: attention.inputAt) }
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
