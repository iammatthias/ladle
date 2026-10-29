import Foundation
import Observation

/// One server and its single account: the connection lifecycle, sign-in, the record stores, and
/// the chat operations. The app holds one per `ServerRecord`, in a `SessionStore`.
///
/// After `start()` it connects, presents the saved bearer token if there is one, and reconnects
/// with backoff when the connection drops. Every frame goes through `ReplayStore`, so the order
/// of live deliveries and history pages never matters (§2.3).
@MainActor
@Observable
public final class ServerSession {
    public enum Status: Hashable, Sendable {
        case offline
        case connecting
        /// Connected without an identity; `server` says which schemes sign in.
        case signedOut
        case signingIn
        case signedIn
        case reconnecting(attempt: Int, delay: Duration)
        /// No automatic reconnect until the user acts (§1.1).
        case stopped(Stop)
    }

    public enum Stop: Hashable, Sendable {
        /// The server sent `denied` outside a reply.
        case denied(String)
        /// The WebSocket upgrade was refused, such as 403 for an `Origin` the server rejects.
        case rejected(status: Int)
        /// The server closed the connection until the user signs in (`CloseAdvice`): it revoked
        /// the credentials, which `signInNeeded` explains, or the connection never signed in.
        case signedOut
    }

    public enum Failure: Error, Hashable, Sendable {
        case notConnected
        case notSignedIn
        case unsupported(capability: String)
        /// The result listed no `write_url` for an attachment (§4.8.3).
        case attachmentNotAccepted
    }

    /// The seams tests replace: the transport, the clock, and the random parts.
    public struct Environment: Sendable {
        public var makeTransport: @Sendable (ServerRecord) -> any FrameTransport
        public var sleep: @Sendable (Duration) async throws -> Void
        /// A factor in [0.5, 1.5) applied to each backoff delay.
        public var jitter: @Sendable () -> Double
        public var makeRequestID: @Sendable () -> String
        /// The unguessable `state` of an email proposal (§4.11.1).
        public var makeState: @Sendable () -> String
        public var agent: String
        /// `limit` of a history page that pages backward.
        public var pageSize: Int
        /// How long a signed-in connection must last before backoff starts over.
        public var stableAfter: Duration
        /// The HTTP `PUT` of an attachment to its `write_url` (§4.8.3).
        public var writeEmbed: EmbedWrite
        /// The fetch of a custom emoji catalog (`ext:emoji`).
        public var fetchEmojiCatalog: @Sendable (URL) async throws -> Data
        /// The GET of `?apron_connection_status=1` after a failed upgrade.
        public var fetchConnectionStatus: ConnectionStatusFetch
        /// The least time between two read cursors sent for one room. Each is a frame, and
        /// Cloudflare's server closes a connection over 60 frames a minute.
        public var readCursorInterval: Duration

        public init(
            makeTransport: @escaping @Sendable (ServerRecord) -> any FrameTransport,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.5 ..< 1.5) },
            makeRequestID: @escaping @Sendable () -> String = { UUID().uuidString },
            makeState: @escaping @Sendable () -> String = { UUID().uuidString + UUID().uuidString },
            agent: String = "ladle-ios/0.1",
            pageSize: Int = 50,
            stableAfter: Duration = .seconds(30),
            writeEmbed: @escaping EmbedWrite = EmbedWriter.live,
            fetchEmojiCatalog: @escaping @Sendable (URL) async throws -> Data = EmojiCatalogFetch.live,
            fetchConnectionStatus: @escaping ConnectionStatusFetch = ConnectionStatusProbe.live,
            readCursorInterval: Duration = .seconds(5)
        ) {
            self.makeTransport = makeTransport
            self.sleep = sleep
            self.jitter = jitter
            self.makeRequestID = makeRequestID
            self.makeState = makeState
            self.agent = agent
            self.pageSize = pageSize
            self.stableAfter = stableAfter
            self.writeEmbed = writeEmbed
            self.fetchEmojiCatalog = fetchEmojiCatalog
            self.fetchConnectionStatus = fetchConnectionStatus
            self.readCursorInterval = readCursorInterval
        }

        public static let live = Environment(makeTransport: { record in
            WebSocketTransport(url: record.url, origin: record.origin)
        })
    }

    public private(set) var record: ServerRecord
    public private(set) var status: Status = .offline
    /// The latest `server` frame (§3.1).
    public private(set) var server: ServerInfo?
    public private(set) var you: UserObject?
    /// The address a code was mailed to, while the proposing connection lasts (§4.11.2).
    public private(set) var pendingEmail: String?
    /// What the server said when it would not take a connection, such as "Demo temporarily
    /// unavailable", until the next connection. Fetched once per failed upgrade (`Connection.probe`).
    public private(set) var unavailableMessage: String?
    /// Why the saved token stopped working, until the user signs in again.
    public private(set) var signInNeeded: String?
    public private(set) var store = ReplayStore()
    public private(set) var users = UserDirectory()
    public private(set) var joinedRoomIDs: Set<String> = []
    /// Transient notices (§3.5.3), newest last. Never installed as snapshots.
    public private(set) var notices: [Notice] = []
    public private(set) var histories: [String: RoomHistory] = [:]
    /// Each room's first page while it loads, so a second `open` waits for it.
    @ObservationIgnored private var openings: [String: Task<Void, Error>] = [:]
    /// This user's read cursor per room (§4.6): the server's, or the one this device sent.
    public private(set) var readCursors: [String: LogID] = [:]
    /// How far this user has read each room on this device.
    public private(set) var readPositions: [String: LogID] = [:]
    private var formerUserIDs: Set<String> = []
    /// The fraction written of each of this user's uploads in flight, by `embed_id` (§4.8.3).
    public internal(set) var uploadProgress: [String: Double] = [:]
    /// Custom emoji catalogs fetched, by `catalog_url` (`ext:emoji`).
    public internal(set) var emojiCatalogs: [URL: EmojiCatalog] = [:]
    /// The catalog URLs asked for, fetched or failed: none is fetched twice.
    @ObservationIgnored var emojiCatalogsAsked: Set<URL> = []

    /// What to call this server: the name the user gave it, else the server's `title` (§3.1),
    /// else its host. Shown with the host where the user picks a server, so a server can't pass
    /// as another by copying its title.
    public var serverName: String {
        guard record.label == ServerRecord.defaultLabel(for: record.url),
              let title = server?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return record.label }
        return TextDirection.withoutOverrides(title)
    }

    /// The server's `avatar` (§3.1), where avatars may load from.
    public var serverAvatarURL: URL? {
        guard let avatar = server?.avatar, let url = URL(string: avatar), mediaPolicy.allowsAvatar(url) else { return nil }
        return url
    }

    /// Whether this account signed in with scheme `guest`.
    public var isGuest: Bool { record.account?.scheme == "guest" }

    /// Whether this user may write: post, react, reply, edit, move, delete, join, leave and start
    /// threads (the `write` row of `ext:limits`). `permissions.write` says so; a server from before
    /// EXTENSIONS.md said it for every guest with `ext.settings.guest_posting: false` instead.
    public var mayWrite: Bool {
        guard permissions.write else { return false }
        let legacyReadOnlyGuests = server.map { $0.has("ext:settings") && $0.ext?["settings"]?["guest_posting"]?.boolValue == false } ?? false
        return !(isGuest && legacyReadOnlyGuests)
    }

    /// Called when the account on `record` changes, so the owner can persist it.
    public var onRecordChange: (@MainActor (ServerRecord) -> Void)?

    private let tokens: any TokenStore
    private let positions: any ReadPositionStore
    let environment: Environment
    private var connection: Connection?
    private var runTask: Task<Void, Never>?

    public init(record: ServerRecord, tokens: any TokenStore, positions: any ReadPositionStore = InMemoryReadPositionStore(),
                environment: Environment = .live) {
        self.record = record
        self.tokens = tokens
        self.positions = positions
        self.environment = environment
    }

    // MARK: Lifecycle

    /// Connects, and keeps reconnecting until `stop()`. A no-op while running.
    public func start() {
        guard runTask == nil else { return }
        status = .connecting
        runTask = Task { await run() }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        await connection?.close()
        connection = nil
        unavailableMessage = nil
        status = .offline
    }

    /// Replaces the record; a changed address or origin reconnects, also after a refused upgrade.
    public func update(_ newRecord: ServerRecord) async {
        let reconnect = newRecord.url != record.url || newRecord.origin != record.origin
        record = newRecord
        guard reconnect else { return }
        await stop()
        start()
    }

    /// Forgets the token and the account, and reconnects without an identity.
    public func signOut() async {
        try? tokens.setToken(nil, for: record.id)
        setAccount(nil)
        await stop()
        resetChatState()
        you = nil
        start()
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            status = .connecting
            let connection = Connection(transport: environment.makeTransport(record), makeRequestID: environment.makeRequestID)
            var minimumDelay = Duration.zero
            var stayedUp = false
            var upgradeFailure: UpgradeFailure?
            do {
                server = try await connection.connect()
                unavailableMessage = nil
                self.connection = connection
                let reader = Task { for await notification in connection.notifications { handle(notification) } }
                let resumes = resumesSavedToken
                resumesSavedToken = true
                if resumes, let token = try? tokens.token(for: record.id) {
                    await resume(with: token, on: connection)
                } else {
                    status = .signedOut
                }
                let opened = ContinuousClock.now
                await reader.value
                stayedUp = status == .signedIn && ContinuousClock.now - opened >= environment.stableAfter
            } catch Connection.Failure.rejected(let code) {
                upgradeFailure = .rejected(code)
            } catch is RPCError {
            } catch Connection.Failure.invalidServerFrame {
            } catch {
                upgradeFailure = .unreachable
            }

            await connection.close()
            if self.connection === connection { self.connection = nil }
            pendingEmail = nil
            for roomID in histories.keys { histories[roomID]?.isLive = false }
            if Task.isCancelled { return }
            if let upgradeFailure {
                let report = await Connection.probe(url: record.url, origin: record.origin, fetch: environment.fetchConnectionStatus)
                if Task.isCancelled { return }
                unavailableMessage = report?.message
                minimumDelay = report?.retryAfter ?? .zero
                if case .rejected(let code) = upgradeFailure, !(code == 429 || code >= 500) {
                    status = .stopped(.rejected(status: code))
                    break
                }
            }
            if let error = await connection.connectionError {
                if error.code == RPCError.Code.denied {
                    status = .stopped(.denied(error.message))
                    break
                }
                minimumDelay = max(minimumDelay, error.retryAfter ?? .zero)
            }
            if let frame = await connection.closeFrame {
                switch CloseAdvice(frame) {
                case .reconnect:
                    break
                case .backOff:
                    minimumDelay = max(minimumDelay, CloseAdvice.backOffDelay)
                case .awaitSignIn:
                    status = .stopped(.signedOut)
                case .credentialsRevoked(let reason):
                    try? tokens.setToken(nil, for: record.id)
                    setAccount(nil)
                    signInNeeded = reason
                    status = .stopped(.signedOut)
                }
                if status == .stopped(.signedOut) { break }
            }

            attempt = stayedUp ? 1 : attempt + 1
            let delay = max(Self.backoff(attempt: attempt, jitter: environment.jitter()), minimumDelay)
            status = .reconnecting(attempt: attempt, delay: delay)
            do { try await environment.sleep(delay) } catch { return }
        }
        runTask = nil
    }

    /// A connection that never reached the server's greeting, the only time the probe runs.
    private enum UpgradeFailure {
        case rejected(Int)
        case unreachable
    }

    /// `min(60 s, 1 s × 2^min(6, attempt − 1))`, scaled by `jitter`: Cloudflare's client guide
    /// asks for 1 s doubling to 60 s, ±50%.
    public static func backoff(attempt: Int, jitter: Double) -> Duration {
        let exponent = min(6, max(0, attempt - 1))
        let base = min(Duration.seconds(60), .seconds(1) * (1 << exponent))
        return base * jitter
    }

    // MARK: Sign-in

    /// Sends one `auth`. A sign-in pipelines `room_list` right behind it (§3.2.2). It goes on a
    /// connection with no identity yet: a signed-in one is replaced first, since servers refuse a
    /// second `auth` ("Identity switching requires reconnect"), and a stopped session connects
    /// again. Neither presents the saved token, which stays saved until this sign-in succeeds.
    @discardableResult
    public func signIn(_ method: SignIn) async throws -> SignInOutcome {
        let stopped = if case .stopped = status { true } else { false }
        if status == .signedIn || stopped || connection == nil {
            await stop()
            resumesSavedToken = false
            start()
            let deadline = ContinuousClock.now + .seconds(20)
            while status != .signedOut {
                switch status {
                case .stopped, .reconnecting: throw Failure.notConnected
                default: break
                }
                guard ContinuousClock.now < deadline else { throw Failure.notConnected }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        guard let connection else { throw Failure.notConnected }
        return try await authenticate(method, on: connection)
    }

    /// False for the one connection a `signIn` opens, which must not resume the saved token.
    @ObservationIgnored private var resumesSavedToken = true

    private func resume(with token: String, on connection: Connection) async {
        do {
            try await authenticate(.token(token), on: connection)
        } catch let error as RPCError where error.code == RPCError.Code.denied || error.code == RPCError.Code.invalidParams {
            try? tokens.setToken(nil, for: record.id)
            setAccount(nil)
            signInNeeded = error.message
            status = .signedOut
        } catch {
            await connection.close()
        }
    }

    @discardableResult
    private func authenticate(_ method: SignIn, on connection: Connection) async throws -> SignInOutcome {
        let auth = try await connection.send("auth", params: method.params(agent: environment.agent, state: environment.makeState()))
        let rooms = method.authenticates ? try await connection.send("room_list", params: Self.roomListParams) : nil
        let before = status
        if method.authenticates { status = .signingIn }
        let result: JSONValue
        do {
            result = try await auth.value
        } catch {
            status = before
            throw error
        }
        guard let identity = UserObject(result["you"]) else {
            status = before
            guard case .emailProposal(let address) = method else { throw Failure.notSignedIn }
            pendingEmail = address
            return .codeSent(to: address)
        }
        if let previous = you, previous.userID != identity.userID { resetChatState() }
        readPositions = positions.positions(server: record.id, user: identity.userID)
        var bearer = result["token"]?.stringValue
        if bearer == nil, case .token(let presented) = method { bearer = presented }
        try tokens.setToken(bearer, for: record.id)
        you = identity
        users.replace(with: identity)
        pendingEmail = nil
        signInNeeded = nil
        setAccount(ServerRecord.Account(userID: identity.userID, name: identity.json["name"]?.stringValue, scheme: method.scheme))
        status = .signedIn
        if let rooms, let listing = try? await rooms.value { applyRoomList(listing) }
        await catchUp(on: connection)
        Task { await drainOutbox() }
        return .signedIn(identity)
    }

    private static let roomListParams: JSONValue = ["filter": "joined", "members": true]

    /// The signed-in account changed its `user_id` (§3.3.3: `you` replaces the connection's
    /// identity; logged records keep the old one, which clients may treat as the new). The saved
    /// account, the read positions and the queued messages follow it, and the old id stays ours.
    private func followRename(from old: String, to new: String) {
        users.rename(from: old, to: new)
        formerUserIDs.insert(old)
        positions.rename(server: record.id, from: old, to: new)
        for index in outbox.indices where outbox[index].userID == old { outbox[index].userID = new }
        if let kept = users.user(new).flatMap(UserObject.init) { you = kept }
        if let account = record.account {
            setAccount(ServerRecord.Account(userID: new, name: account.name, scheme: account.scheme))
        }
    }

    /// Whether `userID` is this account's, now or before it changed its `user_id`.
    public func isYou(_ userID: String) -> Bool {
        userID == you?.userID || formerUserIDs.contains(userID)
    }

    private func setAccount(_ account: ServerRecord.Account?) {
        guard record.account != account else { return }
        record.account = account
        onRecordChange?(record)
    }

    private func resetChatState() {
        store = ReplayStore()
        users = UserDirectory()
        joinedRoomIDs = []
        notices = []
        histories = [:]
        readCursors = [:]
        readPositions = [:]
        formerUserIDs = []
    }

    // MARK: Frames

    private func handle(_ notification: WireNotification) {
        let params = notification.params
        switch notification.method {
        case "server":
            if let info = ServerInfo(params: params) { server = info }
        case "message":
            if case .notice(let notice) = MessageFrame(params: params) { notices.append(notice) }
        case "room_update":
            for room in params?["joined"]?.arrayValue ?? [] {
                if let roomID = room["room_id"]?.stringValue { joinedRoomIDs.insert(roomID) }
            }
            for room in params?["left"]?.arrayValue ?? [] {
                if let roomID = room["room_id"]?.stringValue { joinedRoomIDs.remove(roomID) }
            }
            mergeUsers(params?["users"])
        case "user":
            if let current = UserObject(params?["you"]) {
                if let you, current.userID != you.userID { followRename(from: you.userID, to: current.userID) }
                users.merge(current)
                if current.userID == you?.userID, let kept = users.user(current.userID) { you = UserObject(kept) }
            }
            if let current = UserObject(params?["new"]) {
                if let old = UserObject(params?["old"]), old.userID != current.userID {
                    if old.userID == you?.userID { followRename(from: old.userID, to: current.userID) } else { users.rename(from: old.userID, to: current.userID) }
                }
                users.merge(current)
                if current.userID == you?.userID, let kept = users.user(current.userID) { you = UserObject(kept) }
            }
        case "activity":
            if you != nil, let sender = params?["from"]?["user_id"]?.stringValue, isYou(sender),
               let roomID = OpaqueID.validated(params?["room_id"]), let read = LogID(params?["read_message_id"]),
               readCursors[roomID].map({ $0 < read }) ?? true {
                readCursors[roomID] = read
                advancePosition(roomID, to: read)
            }
        default:
            break
        }
        guard let records = Records(notification: notification) else { return }
        install(records)
        advanceLiveCheckpoints(records)
    }

    /// Installs records, then raises the retention floors their rooms state, which drops the
    /// snapshots the server has expired.
    private func install(_ records: Records) {
        store.apply(records)
        for (room, delivery) in records.rooms {
            if let floor = delivery.floor { store.raiseFloor(of: room.roomID, to: floor) }
        }
    }

    private func applyRoomList(_ result: JSONValue) {
        install(Records(roomListResult: result))
        joinedRoomIDs = Set((result["joined"]?.arrayValue ?? []).compactMap { $0["room_id"]?.stringValue })
        mergeUsers(result["users"])
    }

    private func mergeUsers(_ value: JSONValue?) {
        for element in value?.arrayValue ?? [] {
            if let user = UserObject(element) { users.merge(user) }
        }
    }

    /// A live record in a caught-up room moves its checkpoint, so the next catch-up starts there.
    private func advanceLiveCheckpoints(_ records: Records) {
        var latest: [String: LogID] = [:]
        func note(_ roomID: String?, _ logID: LogID?) {
            guard let roomID, let logID else { return }
            latest[roomID] = max(latest[roomID] ?? logID, logID)
        }
        for (room, _) in records.rooms { note(room.roomID, room.logID) }
        for message in records.messages { note(message.roomID, message.logID) }
        for set in records.reactions { note(set.roomID, set.logID) }
        for membership in records.memberships { note(membership.roomID, membership.logID) }
        for (roomID, logID) in latest where histories[roomID]?.isLive == true {
            if let checkpoint = histories[roomID]?.checkpoint, checkpoint >= logID { continue }
            histories[roomID]?.checkpoint = logID
        }
    }

    // MARK: History

    /// Loads the newest page of a room once (§4.3.5 step 3, without a checkpoint). A call while
    /// that page loads returns once it has.
    public func open(_ roomID: String) async throws {
        if let opening = openings[roomID] { return try await opening.value }
        guard histories[roomID] == nil, server?.has("history") == true else { return }
        histories[roomID] = RoomHistory()
        let opening = Task {
            do {
                let page = try await history(["room_id": .string(roomID), "limit": .number(String(environment.pageSize))])
                histories[roomID]?.receivedBackward(page)
                histories[roomID]?.checkpoint = page.latestLogID
                histories[roomID]?.isLive = true
            } catch {
                histories[roomID] = nil
                throw error
            }
            await listThreads(of: roomID)
        }
        openings[roomID] = opening
        defer { openings[roomID] = nil }
        try await opening.value
    }

    /// Installs the room's threads this user has not joined (§4.2.1). Their records are in their
    /// own logs (§4.3.1), so this listing is how a member of the room learns of threads started
    /// while they were away. A refused listing leaves the threads already known. A thread is not
    /// listed: both reference servers refuse nested threads, and they limit `room_list`.
    private func listThreads(of roomID: String, on connection: Connection? = nil) async {
        guard server?.has("rooms") == true, store.room(roomID)?.parentRoomID == nil,
              let connection = connection ?? self.connection else { return }
        let params: JSONValue = ["parent_room_id": .string(roomID), "filter": "not_joined"]
        guard let result = try? await connection.request("room_list", params: params) else { return }
        install(Records(roomListResult: result))
    }

    /// Loads the page before the oldest one loaded, while there is one (§4.3.2).
    public func loadOlder(_ roomID: String) async throws {
        guard canLoadOlder(roomID), let state = histories[roomID], !state.isLoading, let before = state.olderBefore else { return }
        histories[roomID]?.isLoading = true
        defer { histories[roomID]?.isLoading = false }
        try await page(roomID, before: before, limit: environment.pageSize)
    }

    /// Pages a room back until it holds a message, as a link to it opens (link.apron.chat SPEC
    /// §2): the timeline stays one unbroken run from the newest page. True when the room shows
    /// the message; false once the loaded history reaches back past it without it (deleted,
    /// moved, or never in this room), or there is no more. Stops when its task is cancelled.
    public func reveal(_ messageID: LogID, in roomID: String) async throws -> Bool {
        try await open(roomID)
        func shown() -> Bool { timeline(roomID).contains { $0.messageID == messageID } }
        while !shown(), !Task.isCancelled, canLoadOlder(roomID), let before = histories[roomID]?.olderBefore, before >= messageID {
            try await page(roomID, before: before, limit: 200)
        }
        return shown()
    }

    private func page(_ roomID: String, before: LogID, limit: Int) async throws {
        let page = try await history(["room_id": .string(roomID), "before": before.json, "limit": .number(String(limit))])
        histories[roomID]?.receivedBackward(page)
    }

    /// After a sign-in, pages each opened room forward from its checkpoint until `more` is false.
    private func catchUp(on connection: Connection) async {
        for roomID in histories.keys.sorted(by: codePointLess) {
            guard var after = histories[roomID]?.checkpoint?.successor else { continue }
            while true {
                let params: JSONValue = ["room_id": .string(roomID), "after": after.json, "limit": 200]
                guard let page = try? await history(params, on: connection) else { break }
                if let latest = page.latestLogID { histories[roomID]?.checkpoint = latest }
                guard page.more, let next = page.lastLogID?.successor else { break }
                after = next
            }
            histories[roomID]?.isLive = true
            await listThreads(of: roomID, on: connection)
        }
    }

    private func history(_ params: JSONValue, on connection: Connection? = nil) async throws -> HistoryPage {
        guard let connection = connection ?? self.connection else { throw Failure.notConnected }
        let result = try await connection.request("history", params: params)
        install(Records(historyResult: result))
        let page = HistoryPage(result)
        if let roomID = params["room_id"]?.stringValue, let floor = page.floor { store.raiseFloor(of: roomID, to: floor) }
        return page
    }

    /// Whether older history may still be loaded: the server said there is more, and it is not
    /// below the room's retention floor.
    public func canLoadOlder(_ roomID: String) -> Bool {
        guard let state = histories[roomID], state.more, let before = state.olderBefore else { return false }
        return store.floor(of: roomID).map { before >= $0 } ?? true
    }

    // MARK: Operations

    /// Posts plain text (§3.5.1), or runs a command (§4.1): text that starts with `/` goes as a
    /// `command`, and `//` sends a message that starts with `/`. Returns the new `message_id`, or
    /// nil for a command or when the server logged nothing. A post into a room this user has
    /// not joined joins it first, or the message would never come back (§4.2.2).
    ///
    /// Each attachment goes as an `upload` embed titled with its name (§4.8.4), and is written to
    /// the `write_url` the result lists for it once the result arrives. The writes run on their
    /// own; `uploadProgress` follows them, and a failed one comes back as a Not sent item in the
    /// outbox, since the server drops the embed from the message (§4.8.3).
    @discardableResult
    public func send(_ text: String, in roomID: String, replyTo: LogID? = nil, mentions: [String] = [], attachments: [Attachment] = [],
                     id: String? = nil) async throws -> LogID? {
        let draft = Draft(text: text)
        if !draft.isCommand, !joinedRoomIDs.contains(roomID), server?.has("rooms") == true, connection != nil, status == .signedIn {
            try await join(roomID)
        }
        var body: [String: JSONValue] = ["text": .string(draft.text), "format": "plain"]
        if !mentions.isEmpty { body["mentions"] = .array(mentions.map(JSONValue.string)) }
        if !attachments.isEmpty { body["embeds"] = .array(attachments.map(Self.uploadEmbed)) }
        var params: [String: JSONValue] = ["room_id": .string(roomID), "body": .object(body)]
        if let replyTo { params["reply_to"] = ["message_id": replyTo.json] }
        let result = try await request(draft.isCommand ? "command" : "message", .object(params), id: id)
        startWrites(for: attachments, listedIn: result, roomID: roomID)
        return draft.isCommand ? nil : LogID(result["message_id"])
    }

    /// Composer text as §4.1 reads it.
    public struct Draft: Hashable, Sendable {
        /// The text to send: a `//` message loses its first slash.
        public var text: String
        public var isCommand: Bool

        public init(text: String) {
            if text.hasPrefix("//") {
                self.text = String(text.dropFirst())
                isCommand = false
            } else {
                self.text = text
                isCommand = text.hasPrefix("/")
            }
        }
    }

    // MARK: Outbox

    /// A message waiting to be sent (UX spec 4.2). It keeps its request `id` across retries and
    /// reconnects, so a server that deduplicates logs it once (§1.2).
    public struct PendingMessage: Identifiable, Hashable, Sendable {
        public enum State: Hashable, Sendable {
            case sending
            /// Not sent, with the reason; it waits for Retry or Delete.
            case failed(String)
        }

        public let id: String
        public let roomID: String
        public let text: String
        public let replyTo: LogID?
        public let mentions: [String]
        public let attachments: [Attachment]
        /// Who queued it; it sends only as that user.
        public internal(set) var userID: String?
        public let queuedAt: Date
        public var state: State
    }

    /// Queued messages in send order, across rooms.
    public internal(set) var outbox: [PendingMessage] = []
    private var drainingOutbox = false

    /// Queues a message and sends it now if signed in, or on the next sign-in as the same user.
    /// Commands are not queued: they need a connection (UX spec 4.2).
    public func post(_ text: String, in roomID: String, replyTo: LogID? = nil, mentions: [String] = [], attachments: [Attachment] = []) {
        outbox.append(PendingMessage(id: "q-" + environment.makeRequestID(), roomID: roomID, text: text, replyTo: replyTo,
                                     mentions: mentions, attachments: attachments, userID: you?.userID, queuedAt: Date(), state: .sending))
        Task { await drainOutbox() }
    }

    public func retry(_ id: String) {
        guard let index = outbox.firstIndex(where: { $0.id == id }) else { return }
        outbox[index].state = .sending
        Task { await drainOutbox() }
    }

    public func discard(_ id: String) {
        outbox.removeAll { $0.id == id }
    }

    /// Sends queued messages one at a time, in order. A dropped connection or a timeout leaves
    /// the rest queued for the next sign-in.
    func drainOutbox() async {
        guard !drainingOutbox else { return }
        drainingOutbox = true
        defer { drainingOutbox = false }
        while status == .signedIn, let item = outbox.first(where: { $0.state == .sending }) {
            guard item.userID == nil || item.userID == you?.userID else {
                mark(item.id, .failed("Queued while signed in as someone else."))
                continue
            }
            do {
                try await send(item.text, in: item.roomID, replyTo: item.replyTo, mentions: item.mentions, attachments: item.attachments,
                               id: item.id)
                outbox.removeAll { $0.id == item.id }
            } catch let error as RPCError {
                if let wait = error.retryAfter {
                    try? await environment.sleep(wait)
                } else if error.code == RPCError.Code.tooLarge {
                    mark(item.id, .failed(item.attachments.isEmpty ? "Too long for this server." : "Too large for this server."))
                } else {
                    mark(item.id, .failed(error.message.isEmpty ? "The server refused it (\(error.code))." : error.message))
                }
            } catch {
                return
            }
        }
    }

    private func mark(_ id: String, _ state: PendingMessage.State) {
        if let index = outbox.firstIndex(where: { $0.id == id }) { outbox[index].state = state }
    }

    /// Saves new text, sending every other client field again (§4.4).
    public func edit(_ message: MessageSnapshot, text: String) async throws {
        try require("edit")
        var body = message.body?.objectValue ?? [:]
        body["text"] = .string(text)
        var snapshot = message
        snapshot.body = .object(body)
        _ = try await request("message", .object(save(snapshot, in: message.roomID)))
    }

    /// Moves a message to another room (§4.4): a save with the new `room_id` and every other
    /// client field as stored, which is all Cloudflare's demo accepts from a user moving someone
    /// else's message.
    public func move(_ message: MessageSnapshot, to roomID: String) async throws {
        try require("edit")
        _ = try await request("message", .object(save(message, in: roomID)))
    }

    /// A save of `message` in `roomID` (§4.4 replaces the client fields): its `body`, `reply_to`
    /// and `ext` as stored.
    private func save(_ message: MessageSnapshot, in roomID: String) -> [String: JSONValue] {
        var params: [String: JSONValue] = ["message_id": message.messageID.json, "room_id": .string(roomID)]
        params["body"] = message.body
        params["reply_to"] = message.replyTo.map { ["message_id": $0.json] }
        params["ext"] = message.ext
        return params
    }

    /// What this user may do: `you.ext.permissions` under capability `ext:permissions`
    /// (EXTENSIONS.md). Read from `you` only; without the capability, the defaults.
    public var permissions: Permissions {
        guard server?.has("ext:permissions") == true else { return Permissions() }
        return Permissions(you?.json["ext"]?["permissions"])
    }

    /// Whether to offer creating a top-level room. A server that tells each user what they may do
    /// (`ext:permissions`, as Cloudflare's demo) lets only admins and moderators create one;
    /// elsewhere anyone may. Threads are open to everyone who may post.
    public var mayCreateRooms: Bool {
        guard server?.has("ext:permissions") == true else { return true }
        return !Set(you?.roles ?? []).isDisjoint(with: ["admin", "mod", "moderator"])
    }

    /// Whether this user may move the message: their own, or anyone's with `move_any`.
    public func mayMove(_ message: MessageSnapshot) -> Bool {
        guard status == .signedIn, server?.has("edit") == true, mayWrite, !message.isTombstone else { return false }
        return isYou(message.from.userID) || permissions.moveAny
    }

    /// Where a message may move: into a thread of its room, or out of a thread to the room it
    /// belongs to or another of that room's threads, as apron-web offers.
    public func moveDestinations(for message: MessageSnapshot) -> [String] {
        let family = store.room(message.roomID)?.parentRoomID ?? message.roomID
        let threads = store.roomIDs.filter { store.room($0)?.parentRoomID == family }
            .sorted { codePointLess(title(of: $0), title(of: $1)) }
        return ([family] + threads).filter { $0 != message.roomID }
    }

    public func delete(_ message: MessageSnapshot) async throws {
        try require("edit")
        _ = try await request("message", ["message_id": message.messageID.json, "room_id": .string(message.roomID), "deleted": true])
    }

    /// Adds the entry to this user's set on the message, or removes it when present, comparing
    /// entries without U+FE0F (§4.7).
    public func toggleReaction(_ emoji: String, on messageID: LogID) async throws {
        try require("reactions")
        guard let you else { throw Failure.notSignedIn }
        var mine = (store.reactions(on: messageID) ?? []).filter { $0.userIDs.contains(you.userID) }.map(\.emoji)
        let key = ReactionEntry.key(emoji)
        if let index = mine.firstIndex(where: { ReactionEntry.key($0) == key }) { mine.remove(at: index) } else { mine.append(emoji) }
        _ = try await request("reactions", ["message_id": messageID.json, "emojis": .array(mine.map(JSONValue.string))])
    }

    public func join(_ roomID: String) async throws {
        try require("rooms")
        _ = try await request("room_join", ["room_id": .string(roomID)])
    }

    public func leave(_ roomID: String) async throws {
        try require("rooms")
        _ = try await request("room_leave", ["room_id": .string(roomID)])
    }

    /// Creates a room, or a thread when `parentRoomID` is set (§4.2.4). Returns its `room_id`.
    @discardableResult
    public func createRoom(title: String, parentRoomID: String? = nil) async throws -> String? {
        try require("rooms")
        var params: [String: JSONValue] = ["title": .string(title)]
        if let parentRoomID { params["parent_room_id"] = .string(parentRoomID) }
        return try await request("room_set", .object(params))["room_id"]?.stringValue
    }

    /// The visible rooms this user has not joined (§4.2.1), installed as records.
    public func listUnjoinedRooms() async throws -> [String] {
        try require("rooms")
        let result = try await request("room_list", ["filter": "not_joined"])
        install(Records(roomListResult: result))
        return (result["not_joined"]?.arrayValue ?? []).compactMap { $0["room_id"]?.stringValue }
    }

    func require(_ capability: String) throws {
        guard server?.has(capability) == true else { throw Failure.unsupported(capability: capability) }
    }

    func request(_ method: String, _ params: JSONValue, id: String? = nil) async throws -> JSONValue {
        guard let connection else { throw Failure.notConnected }
        guard status == .signedIn else { throw Failure.notSignedIn }
        return try await connection.request(method, params: params, id: id)
    }

    // MARK: Reading

    /// The room's messages as the timeline shows them: deleted ones are left out. The store keeps
    /// their tombstones for the replay rule and the projection.
    public func timeline(_ roomID: String) -> [MessageSnapshot] { store.messages(in: roomID).filter { !$0.isTombstone } }

    public func displayName(for user: UserObject) -> String { users.displayName(for: user) }

    /// A user's roles from the kept user object, else from the object given (a message's `from`).
    public func roles(of user: UserObject) -> [String] {
        users.user(user.userID).flatMap(UserObject.init)?.roles ?? user.roles
    }

    /// This user read the room through `messageID`, as apron-web's `markRead` and `readPositions.read`: the position
    /// kept on this device moves forward, and with capability `activity` so does the read cursor,
    /// which goes to the server (§4.6) when it keeps cursors, for this user's other devices.
    /// Neither ever moves back. A room's cursor goes at most once a `readCursorInterval`; one
    /// that moves sooner goes when the interval is up, as the newest then.
    public func markRead(_ roomID: String, through messageID: LogID) async {
        guard status == .signedIn, let server, connection != nil, you != nil else { return }
        advancePosition(roomID, to: messageID)
        guard server.has("activity"), readCursors[roomID].map({ $0 < messageID }) ?? true else { return }
        readCursors[roomID] = messageID
        guard server.keepsReadCursors, !cursorsWaiting.contains(roomID) else { return }
        if let last = cursorSentAt[roomID] {
            let wait = environment.readCursorInterval - (ContinuousClock.now - last)
            if wait > .zero {
                cursorsWaiting.insert(roomID)
                try? await Task.sleep(for: wait)
                cursorsWaiting.remove(roomID)
            }
        }
        guard status == .signedIn, let connection, let cursor = readCursors[roomID] else { return }
        cursorSentAt[roomID] = .now
        try? await connection.notify("activity", params: ["room_id": .string(roomID), "read_message_id": cursor.json])
    }

    /// When each room's cursor last went, and the rooms whose next one waits for the interval.
    @ObservationIgnored private var cursorSentAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var cursorsWaiting: Set<String> = []

    private func advancePosition(_ roomID: String, to messageID: LogID) {
        guard let you, readPositions[roomID].map({ $0 < messageID }) ?? true else { return }
        readPositions[roomID] = messageID
        positions.advance(roomID, to: messageID, server: record.id, user: you.userID)
    }

    /// How far this user has read a room, as apron-web's `readPositions.through`: the furthest
    /// of the position kept on this device, the server's cursor, and this user's newest loaded
    /// message, since one sent from another device says the room was read up to it, even if it
    /// was deleted since. Nil when nothing is known.
    public func readThrough(_ roomID: String) -> LogID? {
        guard you != nil else { return nil }
        let newestOwn = store.messages(in: roomID).last { isYou($0.from.userID) }?.messageID
        return [readPositions[roomID], readCursors[roomID], newestOwn].compactMap { $0 }.max()
    }

    /// The message the New line goes before, as the web's `newDividerBefore`: the first shown
    /// message after `after`, where you had read when the visit opened. None when that message is
    /// your own, or when older messages are still to load and none loaded, deleted or not, is at
    /// or before `after`, since the first unread one may be among them.
    public func newLine(in roomID: String, after: LogID?) -> LogID? {
        guard let after else { return nil }
        let olderAvailable = canLoadOlder(roomID)
        var reached = false
        for message in store.messages(in: roomID) {
            if message.messageID <= after {
                reached = true
                continue
            }
            if !reached, olderAvailable { return nil }
            if message.isTombstone { continue }
            return isYou(message.from.userID) ? nil : message.messageID
        }
        return nil
    }

    /// Loaded messages from others after `readThrough`, or all of them when nothing is known.
    public func unreadCount(in roomID: String) -> Int {
        guard you != nil else { return 0 }
        let read = readThrough(roomID)
        return timeline(roomID).count { message in
            !isYou(message.from.userID) && read.map { $0 < message.messageID } ?? true
        }
    }

    public func title(of roomID: String) -> String {
        TextDirection.withoutOverrides(store.room(roomID)?.title?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? roomID)
    }

    /// The joined rooms, each with the threads known under it, by title. A joined thread whose
    /// parent the user has not joined stands on its own.
    public var roomTree: [RoomNode] {
        let known = store.roomIDs.compactMap { store.room($0) }
        let byTitle = { (lhs: RoomRecord, rhs: RoomRecord) in
            codePointLess(self.title(of: lhs.roomID), self.title(of: rhs.roomID))
        }
        let topLevel = known.filter { room in
            joinedRoomIDs.contains(room.roomID) && room.parentRoomID.map { !joinedRoomIDs.contains($0) } ?? true
        }
        return topLevel.sorted(by: byTitle).map { room in
            let threads = known.filter { $0.parentRoomID == room.roomID }.sorted(by: byTitle)
            return RoomNode(roomID: room.roomID, threadIDs: threads.map(\.roomID))
        }
    }
}

public struct RoomNode: Hashable, Sendable, Identifiable {
    public var roomID: String
    public var threadIDs: [String]
    public var id: String { roomID }

    public init(roomID: String, threadIDs: [String]) {
        self.roomID = roomID
        self.threadIDs = threadIDs
    }
}

/// Paging state of one opened room (§4.3.2, §4.3.5).
public struct RoomHistory: Hashable, Sendable {
    /// `before` of the next older page: the oldest loaded page's `first_log_id − 1`.
    public internal(set) var olderBefore: LogID?
    public internal(set) var more = true
    public internal(set) var isLoading = false
    /// The position through which this room is complete; catch-up pages forward from it.
    var checkpoint: LogID?
    /// Whether live records arrive gaplessly, so they may move the checkpoint.
    var isLive = false

    /// A page older than the oldest loaded moves paging back; one that arrives after an older
    /// one (`loadOlder` and `reveal` both page) changes nothing.
    mutating func receivedBackward(_ page: HistoryPage) {
        let next = page.firstLogID?.predecessor
        if let olderBefore, let next, next >= olderBefore { return }
        more = page.more
        olderBefore = next
        if olderBefore == nil { more = false }
    }
}

struct HistoryPage {
    var firstLogID: LogID?
    var lastLogID: LogID?
    var more: Bool
    var latestLogID: LogID?
    var floor: LogID?

    init(_ result: JSONValue) {
        firstLogID = LogID(result["first_log_id"])
        lastLogID = LogID(result["last_log_id"])
        more = result["more"]?.boolValue ?? false
        latestLogID = LogID(result["latest_log_id"])
        floor = retentionFloor(result)
    }
}

extension RPCError {
    /// `data.retry_after` of a `retry_after` error, capped at a day.
    var retryAfter: Duration? {
        guard code == Code.retryAfter, let seconds = data?["retry_after"]?.doubleValue, seconds > 0 else { return nil }
        return .seconds(min(seconds, 86_400))
    }
}
