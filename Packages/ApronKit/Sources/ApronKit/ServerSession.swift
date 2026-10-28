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
    }

    public enum Failure: Error, Hashable, Sendable {
        case notConnected
        case notSignedIn
        case unsupported(capability: String)
    }

    /// The seams tests replace: the transport, the clock, and the random parts.
    public struct Environment: Sendable {
        public var makeTransport: @Sendable (ServerRecord) -> any FrameTransport
        public var sleep: @Sendable (Duration) async throws -> Void
        /// A factor in [0.8, 1.2) applied to each backoff delay.
        public var jitter: @Sendable () -> Double
        public var makeRequestID: @Sendable () -> String
        /// The unguessable `state` of an email proposal (§4.11.1).
        public var makeState: @Sendable () -> String
        public var agent: String
        /// `limit` of a history page that pages backward.
        public var pageSize: Int
        /// How long a signed-in connection must last before backoff starts over.
        public var stableAfter: Duration

        public init(
            makeTransport: @escaping @Sendable (ServerRecord) -> any FrameTransport,
            sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
            jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8 ..< 1.2) },
            makeRequestID: @escaping @Sendable () -> String = { UUID().uuidString },
            makeState: @escaping @Sendable () -> String = { UUID().uuidString + UUID().uuidString },
            agent: String = "apron-ios/0.1",
            pageSize: Int = 50,
            stableAfter: Duration = .seconds(30)
        ) {
            self.makeTransport = makeTransport
            self.sleep = sleep
            self.jitter = jitter
            self.makeRequestID = makeRequestID
            self.makeState = makeState
            self.agent = agent
            self.pageSize = pageSize
            self.stableAfter = stableAfter
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
    /// Why the saved token stopped working, until the user signs in again.
    public private(set) var signInNeeded: String?
    public private(set) var store = ReplayStore()
    public private(set) var users = UserDirectory()
    public private(set) var joinedRoomIDs: Set<String> = []
    /// Transient notices (§3.5.3), newest last. Never installed as snapshots.
    public private(set) var notices: [Notice] = []
    public private(set) var histories: [String: RoomHistory] = [:]

    /// Called when the account on `record` changes, so the owner can persist it.
    public var onRecordChange: (@MainActor (ServerRecord) -> Void)?

    private let tokens: any TokenStore
    private let environment: Environment
    private var connection: Connection?
    private var runTask: Task<Void, Never>?

    public init(record: ServerRecord, tokens: any TokenStore, environment: Environment = .live) {
        self.record = record
        self.tokens = tokens
        self.environment = environment
    }

    // MARK: Lifecycle

    /// Connects, and keeps reconnecting until `stop()`. A no-op while running.
    public func start() {
        guard runTask == nil else { return }
        runTask = Task { await run() }
    }

    public func stop() async {
        runTask?.cancel()
        runTask = nil
        await connection?.close()
        connection = nil
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
            do {
                server = try await connection.connect()
                self.connection = connection
                let reader = Task { for await notification in connection.notifications { handle(notification) } }
                if let token = try? tokens.token(for: record.id) {
                    await resume(with: token, on: connection)
                } else {
                    status = .signedOut
                }
                let opened = ContinuousClock.now
                await reader.value
                stayedUp = status == .signedIn && ContinuousClock.now - opened >= environment.stableAfter
            } catch Connection.Failure.rejected(let code) {
                status = .stopped(.rejected(status: code))
                break
            } catch {}

            await connection.close()
            if self.connection === connection { self.connection = nil }
            pendingEmail = nil
            for roomID in histories.keys { histories[roomID]?.isLive = false }
            if Task.isCancelled { return }
            if let error = await connection.connectionError {
                if error.code == RPCError.Code.denied {
                    status = .stopped(.denied(error.message))
                    break
                }
                minimumDelay = error.retryAfter ?? .zero
            }

            attempt = stayedUp ? 1 : attempt + 1
            let delay = max(Self.backoff(attempt: attempt, jitter: environment.jitter()), minimumDelay)
            status = .reconnecting(attempt: attempt, delay: delay)
            do { try await environment.sleep(delay) } catch { return }
        }
        runTask = nil
    }

    /// `min(60 s, 0.5 s × 2^min(7, attempt − 1))`, scaled by `jitter`.
    public static func backoff(attempt: Int, jitter: Double) -> Duration {
        let exponent = min(7, max(0, attempt - 1))
        let base = min(Duration.seconds(60), .milliseconds(500) * (1 << exponent))
        return base * jitter
    }

    // MARK: Sign-in

    /// Sends one `auth`. A sign-in pipelines `room_list` right behind it (§3.2.2).
    @discardableResult
    public func signIn(_ method: SignIn) async throws -> SignInOutcome {
        guard let connection else { throw Failure.notConnected }
        return try await authenticate(method, on: connection)
    }

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
        return .signedIn(identity)
    }

    private static let roomListParams: JSONValue = ["filter": "joined", "members": true]

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
                users.merge(current)
                if current.userID == you?.userID, let kept = users.user(current.userID) { you = UserObject(kept) }
            }
            if let current = UserObject(params?["new"]) { users.merge(current) }
        default:
            break
        }
        guard let records = Records(notification: notification) else { return }
        store.apply(records)
        advanceLiveCheckpoints(records)
    }

    private func applyRoomList(_ result: JSONValue) {
        store.apply(Records(roomListResult: result))
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

    /// Loads the newest page of a room once (§4.3.5 step 3, without a checkpoint).
    public func open(_ roomID: String) async throws {
        guard histories[roomID] == nil, server?.has("history") == true else { return }
        histories[roomID] = RoomHistory()
        do {
            let page = try await history(["room_id": .string(roomID), "limit": .number(String(environment.pageSize))])
            histories[roomID]?.receivedBackward(page)
            histories[roomID]?.checkpoint = page.latestLogID
            histories[roomID]?.isLive = true
        } catch {
            histories[roomID] = nil
            throw error
        }
    }

    /// Loads the page before the oldest one loaded, while there is one (§4.3.2).
    public func loadOlder(_ roomID: String) async throws {
        guard let state = histories[roomID], state.canLoadOlder, !state.isLoading, let before = state.olderBefore else { return }
        histories[roomID]?.isLoading = true
        defer { histories[roomID]?.isLoading = false }
        let page = try await history(["room_id": .string(roomID), "before": before.json, "limit": .number(String(environment.pageSize))])
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
        }
    }

    private func history(_ params: JSONValue, on connection: Connection? = nil) async throws -> HistoryPage {
        guard let connection = connection ?? self.connection else { throw Failure.notConnected }
        let result = try await connection.request("history", params: params)
        store.apply(Records(historyResult: result))
        return HistoryPage(result)
    }

    // MARK: Operations

    /// Posts plain text (§3.5.1). Returns the new `message_id`, or nil when the server logged
    /// nothing.
    @discardableResult
    public func send(_ text: String, in roomID: String, replyTo: LogID? = nil) async throws -> LogID? {
        var params: [String: JSONValue] = ["room_id": .string(roomID), "body": ["text": .string(text), "format": "plain"]]
        if let replyTo { params["reply_to"] = ["message_id": replyTo.json] }
        return LogID(try await request("message", .object(params))["message_id"])
    }

    /// Saves new text, sending every other client field again (§4.4).
    public func edit(_ message: MessageSnapshot, text: String) async throws {
        try require("edit")
        var body = message.body?.objectValue ?? [:]
        body["text"] = .string(text)
        var params: [String: JSONValue] = ["message_id": message.messageID.json, "room_id": .string(message.roomID), "body": .object(body)]
        if let replyTo = message.replyTo { params["reply_to"] = ["message_id": replyTo.json] }
        _ = try await request("message", .object(params))
    }

    public func delete(_ message: MessageSnapshot) async throws {
        try require("edit")
        _ = try await request("message", ["message_id": message.messageID.json, "room_id": .string(message.roomID), "deleted": true])
    }

    /// Adds the emoji to this user's set on the message, or removes it when present (§4.7).
    public func toggleReaction(_ emoji: String, on messageID: LogID) async throws {
        try require("reactions")
        guard let you else { throw Failure.notSignedIn }
        var mine = (store.reactions(on: messageID) ?? []).filter { $0.userIDs.contains(you.userID) }.map(\.emoji)
        if let index = mine.firstIndex(of: emoji) { mine.remove(at: index) } else { mine.append(emoji) }
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
        store.apply(Records(roomListResult: result))
        return (result["not_joined"]?.arrayValue ?? []).compactMap { $0["room_id"]?.stringValue }
    }

    private func require(_ capability: String) throws {
        guard server?.has(capability) == true else { throw Failure.unsupported(capability: capability) }
    }

    private func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let connection else { throw Failure.notConnected }
        guard status == .signedIn else { throw Failure.notSignedIn }
        return try await connection.request(method, params: params)
    }

    // MARK: Reading

    public func timeline(_ roomID: String) -> [MessageSnapshot] { store.messages(in: roomID) }

    public func displayName(for user: UserObject) -> String { users.displayName(for: user) }

    public func title(of roomID: String) -> String {
        store.room(roomID)?.title?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? roomID
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
    /// The effective lower bound: `history_log_id`, or `latest_log_id + 1` when that is null.
    public internal(set) var floor: LogID?
    public internal(set) var isLoading = false
    /// The position through which this room is complete; catch-up pages forward from it.
    var checkpoint: LogID?
    /// Whether live records arrive gaplessly, so they may move the checkpoint.
    var isLive = false

    public var canLoadOlder: Bool {
        guard more, let olderBefore else { return false }
        return floor.map { olderBefore >= $0 } ?? true
    }

    mutating func receivedBackward(_ page: HistoryPage) {
        more = page.more
        olderBefore = page.firstLogID?.predecessor
        if olderBefore == nil { more = false }
        floor = page.floor
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
        floor = LogID(result["history_log_id"]) ?? latestLogID?.successor
    }
}

extension RPCError {
    /// `data.retry_after` of a `retry_after` error, capped at a day.
    var retryAfter: Duration? {
        guard code == Code.retryAfter, let seconds = data?["retry_after"]?.doubleValue, seconds > 0 else { return nil }
        return .seconds(min(seconds, 86_400))
    }
}
