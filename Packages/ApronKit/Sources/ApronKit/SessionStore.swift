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
    /// The previews of drafts' links, one for every server, as apron-web keeps one per page.
    public let linkPreviews: DraftLinkPreviews
    /// The theme and mode on this device, kept beside `servers.json`.
    public let appearance: AppearanceSettings
    /// Every room's composer draft, kept beside `servers.json`, its files in `Staged`.
    public let drafts: Drafts
    /// The room and thread descriptions put away with their ×, kept beside `servers.json`.
    public let hiddenDescriptions: HiddenDescriptions
    /// The private rooms someone else added you to whose banner still shows, kept beside `servers.json`.
    public let addedRooms: AddedRooms
    /// The email and external proposals this device made, by `state`, kept beside `servers.json`.
    public let proposals: Proposals
    /// Each account's rooms list order and folded threads, kept beside `servers.json`.
    public let roomArrangement: RoomArrangement
    /// How far each account has seen the reactions to its messages, kept beside `servers.json`.
    public let seenReactions: SeenReactions
    /// Whether anyone attends the app, which every session tells its server (§4.5 `idle`).
    public let attention: Attention
    /// Read Receipts on this device, for every server, kept beside `servers.json`.
    public let receiptSettings: ReceiptSettings
    /// Message notifications and the app badge, for every server, kept beside `servers.json`.
    public let alerts: MessageAlerts
    /// How long history is kept on this device, for every server, kept beside `servers.json`.
    public let historySettings: HistorySettings
    /// Where each server's history is kept (`History`, beside `servers.json`); nil keeps none.
    private let historyFiles: (any HistoryFiles)?

    private let serverStore: ServerStore?
    private let tokens: any TokenStore
    private let positions: any ReadPositionStore
    private let environment: ServerSession.Environment

    /// `serverStore` nil keeps the list, the read positions, the reminders and the drafts in memory
    /// only. A kept store sweeps staged files no draft holds.
    public init(serverStore: ServerStore?, tokens: any TokenStore, environment: ServerSession.Environment = .live,
                notifier: any ReminderNotifier = SilentReminderNotifier(), messageNotifier: (any MessageNotifier)? = nil,
                historyFiles: (any HistoryFiles)? = nil) {
        self.serverStore = serverStore
        self.tokens = tokens
        historySettings = HistorySettings(directory: serverStore?.directory)
        self.historyFiles = historyFiles ?? serverStore.map { FileHistoryFiles(directory: $0.directory) }
        historySettings.keptBytes = self.historyFiles?.sizes() ?? [:]
        positions = serverStore.map { FileReadPositionStore(directory: $0.directory) } ?? InMemoryReadPositionStore()
        reminders = Reminders(store: serverStore.map { FileReminderStore(directory: $0.directory) } ?? InMemoryReminderStore(),
                              notifier: notifier)
        mediaSettings = MediaSettings(directory: serverStore?.directory)
        receiptSettings = ReceiptSettings(directory: serverStore?.directory)
        alerts = MessageAlerts(settings: NotificationSettings(directory: serverStore?.directory),
                               notifier: messageNotifier ?? RecordingMessageNotifier())
        linkPreviews = DraftLinkPreviews(fetch: environment.fetchLinkSite, now: environment.now)
        appearance = AppearanceSettings(directory: serverStore?.directory)
        hiddenDescriptions = HiddenDescriptions(directory: serverStore?.directory)
        addedRooms = AddedRooms(directory: serverStore?.directory)
        proposals = Proposals(directory: serverStore?.directory)
        roomArrangement = RoomArrangement(directory: serverStore?.directory)
        seenReactions = SeenReactions(directory: serverStore?.directory)
        if let directory = serverStore?.directory {
            drafts = Drafts(store: FileDraftStore(directory: directory), staging: directory.appending(path: "Staged", directoryHint: .isDirectory))
            drafts.pruneStaging()
        } else {
            drafts = Drafts()
        }
        self.environment = environment
        attention = Attention(now: environment.now)
        // Read Receipts back on: every server sends how far you read meanwhile.
        receiptSettings.onTurnedOn = { [weak self] in
            guard let self else { return }
            for session in sessions.values { Task { await session.readReceiptsTurnedOn() } }
        }
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

    /// Keeps history this long from now on: what each server keeps is written again at once,
    /// within it, as apron-web's `setRetention` prunes.
    /// History's Clear All Users: deletes every account's kept history on every server; each
    /// signed-in session keeps what it has loaded again as it goes.
    public func clearAllKept() {
        for session in sessions.values { session.forgetKept(of: nil) }
        historyFiles?.remove(server: nil, userID: nil)
        historySettings.keptBytes = [:]
    }

    public func setRetention(_ retention: HistoryRetention) async {
        historySettings.update(retention)
        for session in sessions.values { await session.flushKept() }
    }

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

    /// Stops the session and forgets the server, its token, its reminders, its drafts, the
    /// descriptions put away there, how its rooms list was arranged and the reactions seen there.
    public func remove(_ id: UUID) async {
        if let session = sessions.removeValue(forKey: id) {
            await session.unregisterPush()
            await session.stop()
            session.forgetKept(of: nil)
        }
        historyFiles?.remove(server: id, userID: nil)
        historySettings.keptBytes = historySettings.keptBytes.filter { $0.key.server != id }
        await reminders.removeAll(server: id)
        drafts.removeAll(server: id)
        hiddenDescriptions.removeAll(server: id)
        addedRooms.removeAll(server: id)
        proposals.removeAll(server: id)
        roomArrangement.removeAll(server: id)
        seenReactions.removeAll(server: id)
        records.removeAll { $0.id == id }
        try? tokens.setToken(nil, for: id)
        save()
        await updateBadge()
    }

    @discardableResult
    private func startSession(for record: ServerRecord) -> ServerSession {
        let keeping = historyFiles.map { HistoryKeeping(files: $0, settings: historySettings) }
        let session = ServerSession(record: record, tokens: tokens, positions: positions, mediaSettings: mediaSettings, addedRooms: addedRooms,
                                    roomArrangement: roomArrangement, seenReactions: seenReactions,
                                    keeping: keeping, proposals: proposals, linkPreviews: linkPreviews, receiptSettings: receiptSettings,
                                    environment: environment)
        session.onRecordChange = { [weak self] changed in self?.accountChanged(changed) }
        session.onInput = { [weak self] in self?.attention.input() }
        session.onArrivals = { [weak self] arrivals in
            guard let self else { return }
            Task {
                await self.alerts.arrived(arrivals)
                await self.updateBadge()
            }
        }
        session.onSignedIn = { [weak self, weak session] in
            guard let self, let session else { return }
            Task { await self.syncPush(session) }
            if pushInBuild, alerts.isOn == false,
               session.pushBlocker(inBuild: true, relay: alerts.settings.relay, endpoint: alerts.settings.endpoint) == nil {
                alerts.offerAtSignIn()
            }
        }
        session.onRead = { [weak self] account, roomID, messageID in
            guard let self else { return }
            Task {
                await self.alerts.read(roomID, through: messageID, account: account)
                await self.updateBadge()
            }
        }
        if attention.idle { session.setIdle(true, inputAt: attention.inputAt) }
        sessions[record.id] = session
        session.start()
        return session
    }

    /// This build can register for APNs (its `aps-environment` entitlement, docs/PUSH.md).
    public var pushInBuild = false

    /// Registers push for a session's account where it can alert while Ladle is closed, with
    /// notifications on here; otherwise unregisters it.
    public func syncPush(_ session: ServerSession) async {
        let settings = alerts.settings
        guard alerts.isOn, let account = session.notifyAccount, let endpoint = settings.endpoint,
              session.pushBlocker(inBuild: pushInBuild, relay: settings.relay, endpoint: endpoint) == nil else {
            await session.unregisterPush()
            return
        }
        await session.registerPush(endpoint, pushID: settings.pushID(of: account), scopes: settings.scopes(of: account))
    }

    /// The Notifications switch, or the offer's Turn on or Not now: push and the badge follow it.
    public func setNotifications(_ on: Bool) async {
        if on { await alerts.turnOn() } else { await alerts.turnOff() }
        await syncPush()
        await updateBadge()
    }

    /// Every server registers again: the switch, a scope, the relay or its endpoint changed.
    public func syncPush() async {
        for session in sessions.values { await syncPush(session) }
    }

    /// Every server's unread messages from others (`ServerSession.unreadTotal`).
    public var unreadTotal: Int { sessions.values.reduce(0) { $0 + $1.unreadTotal } }

    /// Shows `unreadTotal` as the app badge, as apron-web does while it is in view.
    public func updateBadge() async {
        await alerts.setBadge(unreadTotal)
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
