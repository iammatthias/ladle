import Foundation
import Observation
import Synchronization

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
        /// An external proposal's `url` was not an `https` page, or `http` on a loopback host (§4.11.5).
        case badSignInPage
        /// No addition is open on this connection for a code to approve (§4.11.1).
        case noAddition
    }

    /// The seams tests replace: the transport, the clock, and the random parts.
    public struct Environment: Sendable {
        public var makeTransport: @Sendable (ServerRecord) -> any FrameTransport
        public var sleep: @Sendable (Duration) async throws -> Void
        /// A factor in [0.5, 1.5) applied to each backoff delay.
        public var jitter: @Sendable () -> Double
        public var makeRequestID: @Sendable () -> String
        /// The unguessable `state` of an email or external proposal (§4.11.1).
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
        /// A site's API, asked about a link in a draft (`DraftLinkPreviews`).
        public var fetchLinkSite: DraftLinkPreviews.Fetch
        /// The least time between two read cursors sent for one room. Each is a frame, and
        /// Cloudflare's server closes a connection over 60 frames a minute.
        public var readCursorInterval: Duration
        /// How typing goes out and how long others show as typing (§4.6).
        public var typing: TypingTimes
        /// The wall clock, which mutes end by (§4.5).
        public var now: @Sendable () -> Date
        /// How long a room's first page waits for its thread listing, so the thread cards come
        /// with its messages. A slow listing still installs when it comes. Real time, not
        /// `sleep`, which tests release one sleep at a time.
        public var threadsWait: Duration
        /// The domains this build may ask passkeys for (`PasskeyDomains.app`).
        public var passkeyDomains: PasskeyDomains
        /// The streaming `GET` of live text (v10 §4.8.5).
        public var readLiveText: LiveTextRead

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
            fetchLinkSite: @escaping DraftLinkPreviews.Fetch = LinkSiteFetch.live,
            readCursorInterval: Duration = .seconds(5),
            typing: TypingTimes = TypingTimes(),
            now: @escaping @Sendable () -> Date = { Date() },
            threadsWait: Duration = .seconds(3),
            passkeyDomains: PasskeyDomains = .app,
            readLiveText: @escaping LiveTextRead = LiveTextFetch.live
        ) {
            self.readLiveText = readLiveText
            self.passkeyDomains = passkeyDomains
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
            self.fetchLinkSite = fetchLinkSite
            self.readCursorInterval = readCursorInterval
            self.typing = typing
            self.now = now
            self.threadsWait = threadsWait
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
    /// Your chosen status (§4.5.1), taken only from `you` (§4.5.2): others' objects about you
    /// carry the shown one. `""` is no status; nil, none known (the default, `online`).
    public private(set) var chosenStatus: String?
    /// Optional statuses this server answered something else for, which the picker stops offering.
    public internal(set) var unsupportedStatuses: Set<String> = []
    /// The address a code was mailed to, while the proposing connection lasts (§4.11.2).
    public private(set) var pendingEmail: String?
    /// What the server said when it would not take a connection, such as "Demo temporarily
    /// unavailable", until the next connection. Fetched once per failed upgrade (`Connection.probe`).
    public private(set) var unavailableMessage: String?
    /// Why the saved token stopped working, until the user signs in again.
    public private(set) var signInNeeded: String?
    /// Whether this account has a token to sign back in with: false for a guest the server gave
    /// none, whose `user_id` ends with its connection (apron-web's `registeredSession`).
    public private(set) var resumable = false
    public private(set) var store = ReplayStore()
    public private(set) var users = UserDirectory()
    public private(set) var joinedRoomIDs: Set<String> = []
    /// Transient notices (§3.5.3), newest last. Never installed as snapshots.
    public internal(set) var notices: [Notice] = []
    public private(set) var histories: [String: RoomHistory] = [:]
    /// Each room's first page while it loads, so a second `open` waits for it.
    @ObservationIgnored private var openings: [String: Task<Void, Error>] = [:]
    /// The rooms whose first page and thread listing are loading, which the timeline holds back.
    public private(set) var held: Set<String> = []
    /// Threads this device started, by the message each was started from (`startThread`).
    @ObservationIgnored var startedThreads: [LogID: String] = [:]
    /// The rooms on screen, which a catch-up pages before the others.
    @ObservationIgnored private var onScreen: Set<String> = []
    /// This user's read cursor per room (§4.6): the server's, or the one this device sent.
    public private(set) var readCursors: [String: LogID] = [:]
    /// The other members' read cursors in each room, by `user_id` (§4.6), for read receipts.
    public private(set) var readers: [String: [String: LogID]] = [:]
    /// Read Receipts on this device, shared with every other server's session.
    public let receiptSettings: ReceiptSettings
    /// The cursor last sent for each room, so turning Read Receipts back on sends only what moved.
    @ObservationIgnored var readSent: [String: LogID] = [:]
    /// Live texts read or being read, by `url` (`ServerSession+LiveText`), the most recently
    /// asked for last.
    @ObservationIgnored var liveTexts: [URL: LiveText] = [:]
    @ObservationIgnored var liveTextOrder: [URL] = []
    /// How far this user has read each room on this device.
    public private(set) var readPositions: [String: LogID] = [:]
    /// Everyone else typing, by `room_id` (§4.6), in the order they last started or refreshed.
    public internal(set) var typing: [String: [Typist]] = [:]
    /// When this user was last said to be typing in each room, and the timers that end it.
    @ObservationIgnored var typingSentAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored var typingIdle: [String: Task<Void, Never>] = [:]
    /// Your pause (§4.5 `mute` without `room_id`) as the server last said; `pause` is it while it lasts.
    public internal(set) var pausedUntil: MuteEnd?
    /// Each room's mute (§4.5 `mute` with its `room_id`) as the server last said; `mute(of:)` reads it.
    public internal(set) var roomMutes: [String: MuteEnd] = [:]
    @ObservationIgnored var muteExpiry: Task<Void, Never>?
    /// Whether the app is idle (§4.5 `idle`), since when, and what this connection's server was told.
    @ObservationIgnored var wantsIdle = false
    @ObservationIgnored var idleInputAt: Date?
    @ObservationIgnored var idleReport: IdleReport?
    @ObservationIgnored var idleSending: Task<Void, Never>?
    /// Waits the server asked for, by what they hold back (`ServerSession+Limits`), and whose.
    public internal(set) var limits: [LimitScope: LimitWait] = [:]
    @ObservationIgnored var limitsUserID: String?
    private var formerUserIDs: Set<String> = []
    /// The fraction written of each of this user's uploads in flight, by `embed_id` (§4.8.3).
    public internal(set) var uploadProgress: [String: Double] = [:]
    /// Custom emoji catalogs fetched, by `catalog_url` (`ext:emoji`).
    public internal(set) var emojiCatalogs: [URL: EmojiCatalog] = [:]
    /// The commands `/help` last listed for this user (`loadCommands(in:)`), kept across
    /// reconnects until a fresh list replaces it.
    public private(set) var commands: CommandHelp?
    /// Who `/help` was last asked as: on which connection, by which user, with which roles.
    @ObservationIgnored private var commandsAskedAs: CommandsAsker?
    /// The room whose next `/help` list is the answer to `loadCommands(in:)`, which the timeline never shows.
    @ObservationIgnored private var commandsNoticeAwaited: String?
    /// Counts connections, so a list asked for on one is not taken as asked on the next.
    @ObservationIgnored private(set) var connectionNumber = 0
    /// The catalog URLs asked for, fetched or failed: none is fetched twice.
    @ObservationIgnored var emojiCatalogsAsked: Set<URL> = []
    /// The current catalog as the gate last let it show, which `emojiCatalog` reuses while
    /// neither changes.
    @ObservationIgnored var gatedEmojiCatalog: (url: URL, gate: MediaGate, shown: EmojiCatalog)?
    /// The viewer's media choices, shared with every other server's session.
    public let mediaSettings: MediaSettings
    /// The private rooms whose "You were added" banner shows, shared with every other server's session.
    public let addedRooms: AddedRooms
    /// The rooms list's order and folded threads, shared with every other server's session.
    public let roomArrangement: RoomArrangement
    /// Rooms that arrive joined without this device asking (`noteArrivals`).
    @ObservationIgnored var arrivals = ArrivalWatch()
    /// Rooms someone else added you to while this session watched (`ArrivalWatch`), as apron-web's
    /// `UnreadTracker.addedTo`: each counts unread from your join (`joinFloor`).
    public internal(set) var addedTo: Set<String> = []
    /// The server answered a `room_join` or `room_leave` with another's `user_id` as `unsupported`
    /// (§4.2.2): adding and removing others is no longer offered.
    public internal(set) var memberChangesUnsupported = false
    /// Where this server's history is kept on the device, and for how long; nil keeps nothing.
    public let keeping: HistoryKeeping?
    /// Everything this session holds or has kept of the server's history: `store` and what the
    /// device holds below what `store` shows. What a kept log and an export are written from.
    public internal(set) var kept = ReplayStore()
    /// Each restored room's kept sync, while its kept log reaches below what `store` shows:
    /// older pages come from the device until it runs out (`page`).
    @ObservationIgnored var keptCoverage: [String: KeptSync] = [:]
    /// When each room was last caught up, as kept.
    @ObservationIgnored var caughtUp: [String: Date] = [:]
    @ObservationIgnored var restoring: Task<Void, Never>?
    @ObservationIgnored var keptSave: Task<Void, Never>?

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
        server?.avatar.flatMap { URL(string: $0) }.flatMap { mediaGate.decide($0, for: .avatar).url }
    }

    /// Whether a token is saved for this server, which the next connection resumes with.
    var hasSavedToken: Bool { ((try? tokens.token(for: record.id)) ?? nil) != nil }

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

    /// Called when the user types in a composer, which is input to `Attention`.
    public var onInput: (@MainActor () -> Void)?

    /// Called when the account on `record` changes, so the owner can persist it.
    public var onRecordChange: (@MainActor (ServerRecord) -> Void)?

    /// The previews of a draft's links that go out with it (`DraftLinkPreviews`), shared by
    /// every server's composer.
    public let linkPreviews: DraftLinkPreviews
    private let tokens: any TokenStore
    private let positions: any ReadPositionStore
    let environment: Environment
    private(set) var connection: Connection?
    private var runTask: Task<Void, Never>?
    /// The email and external proposals this device made, by `state`, shared by every session.
    public let proposals: Proposals
    /// The account whose saved token the server refused, until the next sign-in: a passkey
    /// account then signs back in with a tap (`passkeyHold`), as apron-web holds the session.
    public internal(set) var heldAccount: ServerRecord.Account?
    /// An addition proposed on this connection (§4.11.1), which only it can approve with a code.
    public internal(set) var pendingAddition: PendingAddition?
    /// The page of an external proposal that shows a code, while the proposing connection lasts.
    public internal(set) var pendingPage: URL?
    @ObservationIgnored var pendingProposalState: String?

    public init(record: ServerRecord, tokens: any TokenStore, positions: any ReadPositionStore = InMemoryReadPositionStore(),
                mediaSettings: MediaSettings = MediaSettings(), addedRooms: AddedRooms = AddedRooms(),
                roomArrangement: RoomArrangement = RoomArrangement(), keeping: HistoryKeeping? = nil,
                proposals: Proposals = Proposals(), linkPreviews: DraftLinkPreviews? = nil, receiptSettings: ReceiptSettings = ReceiptSettings(),
                environment: Environment = .live) {
        self.record = record
        self.receiptSettings = receiptSettings
        self.linkPreviews = linkPreviews ?? DraftLinkPreviews(fetch: environment.fetchLinkSite, now: environment.now)
        self.mediaSettings = mediaSettings
        self.addedRooms = addedRooms
        self.proposals = proposals
        self.roomArrangement = roomArrangement
        self.keeping = keeping
        self.tokens = tokens
        self.positions = positions
        self.environment = environment
    }

    // MARK: Lifecycle

    /// Connects, and keeps reconnecting until `stop()`. A no-op while running.
    public func start() {
        guard runTask == nil else { return }
        status = .connecting
        restoreKept()
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
        resumable = false
        heldAccount = nil
        setAccount(nil)
        await stop()
        resetChatState()
        you = nil
        chosenStatus = nil
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
                connectionNumber += 1
                commandsNoticeAwaited = nil
                let reader = Task { for await notification in connection.notifications { handle(notification) } }
                let resumes = resumesSavedToken
                resumesSavedToken = true
                await restoring?.value
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
            pendingPage = nil
            pendingAddition = nil
            clearTyping()
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
                    resumable = false
                    if record.account != nil { heldAccount = record.account }
                    setAccount(nil)
                    forgetKept()
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
        if status == .signedIn || stopped || connection == nil { try await connectAfresh() }
        guard let connection else { throw Failure.notConnected }
        return try await authenticate(method, on: connection)
    }

    /// A new connection that presents no saved token, once its server frame is in.
    func connectAfresh() async throws {
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

    /// False for the one connection a `signIn` opens, which must not resume the saved token.
    @ObservationIgnored private var resumesSavedToken = true

    private func resume(with token: String, on connection: Connection) async {
        do {
            try await authenticate(.token(token), on: connection, resuming: true)
        } catch let error as RPCError where error.code == RPCError.Code.denied || error.code == RPCError.Code.invalidParams {
            try? tokens.setToken(nil, for: record.id)
            resumable = false
            if record.account != nil { heldAccount = record.account }
            setAccount(nil)
            forgetKept()
            signInNeeded = error.message
            status = .signedOut
        } catch {
            await connection.close()
        }
    }

    @discardableResult
    func authenticate(_ method: SignIn, on connection: Connection, resuming: Bool = false) async throws -> SignInOutcome {
        // A sign-in starts without mutes: the server sends those in effect after its result
        // (§4.5), which may be applied before this function sees the result.
        if method.authenticates { resetMutes() }
        let state = environment.makeState()
        if let scheme = method.proposal {
            // Remembered before it goes out: its link may come back before its result does.
            proposals.remember(Proposal(scheme: scheme, kind: .signIn, server: record.id, state: state,
                                        email: { if case .emailProposal(let address) = method { address } else { nil } }(),
                                        expires: environment.now().addingTimeInterval(Proposals.lifetime)), now: environment.now())
        }
        let auth = try await connection.send("auth", params: method.params(agent: environment.agent, state: state))
        let rooms = method.authenticates ? try await connection.send("room_list", params: Self.roomListParams) : nil
        let before = status
        if method.authenticates { status = .signingIn }
        let result: JSONValue
        do {
            result = try await auth.value
        } catch {
            status = before
            if method.proposal != nil { proposals.forget(state) }
            throw error
        }
        guard let identity = UserObject(result["you"]) else {
            status = before
            switch method {
            case .emailProposal(let address):
                pendingEmail = address
                pendingProposalState = state
                return .codeSent(to: address)
            case .externalProposal(let returnURL):
                guard let page = result["url"]?.stringValue.flatMap(URL.init(string:)), SignInPage.accepts(page) else {
                    proposals.forget(state)
                    throw Failure.badSignInPage
                }
                pendingProposalState = state
                if returnURL == nil { pendingPage = page }
                return .page(page, returns: returnURL != nil)
            default:
                throw Failure.notSignedIn
            }
        }
        if let used = usedProposalState(method, state: state) { proposals.forget(used) }
        // Resuming the saved token keeps how the account signed in and what was added since,
        // as apron-web keeps `signedInWith` beside its token.
        let kept = resuming ? record.account.flatMap { $0.userID == identity.userID ? $0 : nil } : nil
        try await adoptSignIn(identity, result: result, method: kept?.scheme ?? method.method, presented: method.presentedToken,
                          registered: method.registers, rooms: rooms, on: connection, added: kept?.added ?? [])
        return .signedIn(identity)
    }

    /// The `state` of the proposal a code or link approved (§4.11.1: approval uses it up).
    private func usedProposalState(_ method: SignIn, state: String) -> String? {
        switch method {
        case .emailCode, .externalCode: pendingProposalState
        default: nil
        }
    }

    /// Makes `identity` this connection's account after a sign-in: the token in `result` (else
    /// the one presented) is saved, the account is recorded as signed in by `method`, and the
    /// rooms listed behind the `auth` are applied. `keepsState` follows a guest becoming an
    /// account under a new `user_id` as a rename, keeping its rooms.
    func adoptSignIn(_ identity: UserObject, result: JSONValue, method: String, presented: String?, registered: Bool,
                     rooms: Connection.Reply?, on connection: Connection, keepsState: Bool = false, added: [String] = []) async throws {
        if let previous = you, previous.userID != identity.userID {
            if keepsState { followRename(from: previous.userID, to: identity.userID) } else { resetChatState() }
        }
        // The listing behind this sign-in is the new baseline; a passkey added to the account
        // sends none, and keeps the one it has.
        if rooms != nil { arrivals.listed = false }
        readPositions = positions.positions(server: record.id, user: identity.userID)
        let bearer = result["token"]?.stringValue ?? presented
        try tokens.setToken(bearer, for: record.id)
        resumable = bearer != nil
        you = identity
        chosenStatus = identity.json["status"]?.stringValue
        users.replace(with: identity)
        pendingEmail = nil
        pendingPage = nil
        pendingProposalState = nil
        signInNeeded = nil
        heldAccount = nil
        setAccount(ServerRecord.Account(userID: identity.userID, name: identity.json["name"]?.stringValue, scheme: method, added: added))
        status = .signedIn
        // A welcome speaks to whoever connected; an account signed in by a code, or given a token
        // of its own, is past it (apron-web's `dropWelcomes`).
        if registered || result["token"]?.stringValue != nil { notices.removeAll(where: \.welcome) }
        // A connection starts attended (§4.5): an idle app says so at once.
        syncIdle()
        if let rooms, let listing = try? await rooms.value { applyRoomList(listing) }
        await catchUp(on: connection)
        Task { await drainOutbox() }
    }

    private static let roomListParams: JSONValue = ["filter": "joined", "members": true]

    /// The signed-in account changed its `user_id` (§3.3.3: `you` replaces the connection's
    /// identity; logged records keep the old one, which clients may treat as the new). The saved
    /// account, the read positions and the queued messages follow it, and the old id stays ours.
    private func followRename(from old: String, to new: String) {
        users.rename(from: old, to: new)
        formerUserIDs.insert(old)
        positions.rename(server: record.id, from: old, to: new)
        roomArrangement.rename(server: record.id, from: old, to: new)
        for index in outbox.indices where outbox[index].userID == old { outbox[index].userID = new }
        if let kept = users.user(new).flatMap(UserObject.init) { you = kept }
        if let account = record.account {
            setAccount(ServerRecord.Account(userID: new, name: account.name, scheme: account.scheme, added: account.added))
        }
    }

    /// A complete `you` from a `me` result (§3.3.1): it replaces what is kept, a changed `user_id`
    /// is followed as a rename, and the saved account takes its name.
    func adopt(_ identity: UserObject) {
        if let you, you.userID != identity.userID { followRename(from: you.userID, to: identity.userID) }
        users.replace(with: identity)
        you = identity
        chosenStatus = identity.json["status"]?.stringValue
        if let account = record.account {
            setAccount(ServerRecord.Account(userID: identity.userID, name: identity.json["name"]?.stringValue, scheme: account.scheme,
                                            added: account.added))
        }
    }

    /// Whether `userID` is this account's, now or before it changed its `user_id`.
    public func isYou(_ userID: String) -> Bool {
        userID == you?.userID || formerUserIDs.contains(userID)
    }

    /// A way back in was added to the signed-in account (§4.10, §4.11.3).
    func noteAdded(_ scheme: String) {
        guard var account = record.account, !account.methods.contains(scheme) else { return }
        account.added.append(scheme)
        setAccount(account)
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
        commands = nil
        commandsAskedAs = nil
        commandsNoticeAwaited = nil
        histories = [:]
        readCursors = [:]
        readers = [:]
        readSent = [:]
        addedTo = []
        readPositions = [:]
        formerUserIDs = []
        clearTyping()
        resetMutes()
        limits = [:]
        memberChangesUnsupported = false
        forgetKept()
    }

    // MARK: Frames

    private func handle(_ notification: WireNotification) {
        let params = notification.params
        switch notification.method {
        case "server":
            if let info = ServerInfo(params: params) { server = info }
        case "message":
            guard case .notice(var notice) = MessageFrame(params: params) else { break }
            if let help = CommandHelp(notice: notice) {
                commands = help
                commandsAskedAs = commandsAsker
                if commandsNoticeAwaited != nil, commandsNoticeAwaited == notice.roomID {
                    commandsNoticeAwaited = nil
                    break
                }
            }
            if status != .signedIn {
                notice.welcome = true
                notices.removeAll(where: \.welcome)
            } else if notice.roomID == nil {
                notice.roomID = onScreen.sorted(by: codePointLess).first
            }
            notices.append(notice)
        case "room_update":
            for room in params?["joined"]?.arrayValue ?? [] {
                if let roomID = room["room_id"]?.stringValue { joinedRoomIDs.insert(roomID) }
            }
            for room in params?["left"]?.arrayValue ?? [] {
                if let roomID = room["room_id"]?.stringValue { joinedRoomIDs.remove(roomID) }
            }
            mergeUsers(params?["users"])
            placeNewRooms()
        case "user":
            if let current = UserObject(params?["you"]) {
                if let you, current.userID != you.userID { followRename(from: you.userID, to: current.userID) }
                users.merge(current)
                if current.userID == you?.userID, let kept = users.user(current.userID) { you = UserObject(kept) }
                if current.userID == you?.userID, let chosen = current.json["status"]?.stringValue { chosenStatus = chosen }
            }
            if let current = UserObject(params?["new"]) {
                if let old = UserObject(params?["old"]), old.userID != current.userID {
                    if old.userID == you?.userID { followRename(from: old.userID, to: current.userID) } else { users.rename(from: old.userID, to: current.userID) }
                }
                users.merge(current)
                if current.userID == you?.userID, let kept = users.user(current.userID) { you = UserObject(kept) }
            }
        case "activity":
            if you != nil, let sender = params?["from"]?["user_id"]?.stringValue,
               let roomID = OpaqueID.validated(params?["room_id"]), let read = LogID(params?["read_message_id"]) {
                if isYou(sender) {
                    if readCursors[roomID].map({ $0 < read }) ?? true {
                        readCursors[roomID] = read
                        advancePosition(roomID, to: read)
                    }
                } else if readers[roomID]?[sender].map({ $0 < read }) ?? true {
                    readers[roomID, default: [:]][sender] = read
                    if let from = UserObject(params?["from"]), from.json["name"]?.stringValue != nil { users.merge(from) }
                }
            }
            applyTyping(params)
        case "status":
            applyStatus(params)
        default:
            break
        }
        guard let records = Records(notification: notification) else { return }
        install(records)
        if notification.method == "room_update" { noteArrivals() }
        advanceLiveCheckpoints(records)
        for message in records.messages where message.logID == message.messageID { endTyping(message.from.userID, in: message.roomID) }
    }

    /// Installs records, then raises the retention floors their rooms state, which drops the
    /// snapshots the server has expired.
    private func install(_ records: Records) {
        store.apply(records)
        kept.apply(records)
        for (room, delivery) in records.rooms {
            if let floor = delivery.floor { raiseFloor(of: room.roomID, to: floor) }
        }
        keptChanged()
    }

    /// The server has expired a room's history below `floor`: what is kept goes too.
    private func raiseFloor(of roomID: String, to floor: LogID) {
        store.raiseFloor(of: roomID, to: floor)
        kept.raiseFloor(of: roomID, to: floor)
    }

    private func applyRoomList(_ result: JSONValue) {
        install(Records(roomListResult: result))
        joinedRoomIDs = Set((result["joined"]?.arrayValue ?? []).compactMap { $0["room_id"]?.stringValue })
        mergeUsers(result["users"])
        arrivals.listed = true
        noteArrivals()
        placeNewRooms()
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

    /// Marks a room as on screen or not, so a catch-up after a reconnect pages it first.
    public func show(_ roomID: String, _ shown: Bool) {
        if shown { onScreen.insert(roomID) } else { onScreen.remove(roomID) }
    }

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
            await listThreads(of: roomID, waitingAtMost: environment.threadsWait)
        }
        openings[roomID] = opening
        held.insert(roomID)
        defer {
            openings[roomID] = nil
            held.remove(roomID)
        }
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

    /// `listThreads`, waited for at most `limit`.
    private func listThreads(of roomID: String, waitingAtMost limit: Duration) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let first = FirstOf(done)
            Task {
                await listThreads(of: roomID)
                first.resume()
            }
            Task {
                try? await Task.sleep(for: limit)
                first.resume()
            }
        }
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

    /// The page before `before`, from what the device keeps while its kept log reaches there,
    /// then from the server (apron-web's `olderPage`).
    private func page(_ roomID: String, before: LogID, limit: Int) async throws {
        if let cover = keptCoverage[roomID] {
            let log = kept.logEntries(of: roomID).filter { entry in cover.start.map { entry.logID >= $0 } ?? true }
            let (slice, more) = LogEntry.slice(log, before: before, limit: limit)
            if !more { keptCoverage[roomID] = nil }
            if let first = slice.first {
                store.apply(Records(entries: slice))
                histories[roomID]?.receivedBackward(HistoryPage(firstLogID: first.logID, more: more || cover.older))
                return
            }
            guard cover.older else {
                histories[roomID]?.more = false
                return
            }
        }
        let page = try await history(["room_id": .string(roomID), "before": before.json, "limit": .number(String(limit))])
        histories[roomID]?.receivedBackward(page)
    }

    /// After a sign-in, pages each opened room forward from its checkpoint until `more` is false.
    private func catchUp(on connection: Connection) async {
        let rooms = histories.keys.sorted(by: codePointLess)
        for roomID in rooms.filter(onScreen.contains) + rooms.filter({ !onScreen.contains($0) }) {
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
        if let roomID = params["room_id"]?.stringValue, let floor = page.floor { raiseFloor(of: roomID, to: floor) }
        if let roomID = params["room_id"]?.stringValue, let latest = page.latestLogID {
            store.noteLatest(of: roomID, latest)
            kept.noteLatest(of: roomID, latest)
        }
        return page
    }

    /// Whether older history may still be loaded: the server said there is more, and it is not
    /// below the room's retention floor.
    public func canLoadOlder(_ roomID: String) -> Bool {
        guard let state = histories[roomID], state.more, let before = state.olderBefore else { return false }
        return store.floor(of: roomID).map { before >= $0 } ?? true
    }

    /// Shows what the device kept of this account's history before the connection signs in, as
    /// apron-web's `ChatClient.restore`: the rooms, users and joined set, each restored room's
    /// newest entries, and its checkpoint, so the sign-in's catch-up goes on from there. False,
    /// changing nothing, once the session holds anything of its own.
    @discardableResult
    func adopt(_ restore: KeptRestore) -> Bool {
        guard you == nil, histories.isEmpty, store == ReplayStore(), record.account?.userID == restore.you.userID else { return false }
        you = restore.you
        for user in restore.users { users.merge(user) }
        joinedRoomIDs = restore.joined
        kept = restore.kept
        store.apply(restore.listing)
        for (room, delivery) in restore.listing.rooms {
            if let floor = delivery.floor { store.raiseFloor(of: room.roomID, to: floor) }
        }
        for (roomID, room) in restore.rooms {
            store.apply(Records(entries: room.window))
            histories[roomID] = room.history
            keptCoverage[roomID] = room.sync
            caughtUp[roomID] = room.sync.caughtUpAt
        }
        readPositions = positions.positions(server: record.id, user: restore.you.userID)
        placeNewRooms()
        return true
    }

    // MARK: Operations

    /// Posts plain text (§3.5.1), or with capability `command` runs a command (§4.1): text that
    /// starts with `/` goes as a `command`, and `//` sends a message that starts with `/`. Returns
    /// the new `message_id`, or nil for a command or when the server logged nothing. A post into a
    /// room this user has not joined joins it first, or the message would never come back (§4.2.2).
    ///
    /// Each attachment goes as an `upload` embed titled with its name (§4.8.4), and is written to
    /// the `write_url` the result lists for it once the result arrives. The writes run on their
    /// own; `uploadProgress` follows them, and a failed one comes back as a Not sent item in the
    /// outbox, since the server drops the embed from the message (§4.8.3).
    @discardableResult
    public func send(_ text: String, in roomID: String, replyTo: LogID? = nil, mentions: [String] = [], links: [Embed] = [],
                     attachments: [Attachment] = [], id: String? = nil) async throws -> LogID? {
        let draft = Draft(text: text, commands: server?.has("command") == true)
        if !draft.isCommand, !joinedRoomIDs.contains(roomID), server?.has("rooms") == true, connection != nil, status == .signedIn {
            try await join(roomID)
        }
        if !draft.isCommand { sentMessage(in: roomID) }
        var body: [String: JSONValue] = ["text": .string(draft.text), "format": "markdown"]
        if !mentions.isEmpty { body["mentions"] = .array(mentions.map(JSONValue.string)) }
        let embeds = links.map(\.json) + attachments.map(Self.uploadEmbed)
        if !embeds.isEmpty { body["embeds"] = .array(embeds) }
        var params: [String: JSONValue] = ["room_id": .string(roomID), "body": .object(body)]
        if let replyTo { params["reply_to"] = ["message_id": replyTo.json] }
        let result = try await request(draft.isCommand ? "command" : "message", .object(params), id: id)
        startWrites(for: attachments, listedIn: result, roomID: roomID)
        return draft.isCommand ? nil : LogID(result["message_id"])
    }

    /// Asks the server which commands this user may run, by sending `/help` in `roomID`: once a
    /// connection, and again only when `you` or its roles change. No server lists its commands in
    /// the `server` frame, so `/help`'s `~private` notice is the source (`CommandHelp`). That
    /// notice comes before the result (§1), and this one is kept out of `notices`: the first
    /// `/help` list in `roomID` after the request is its answer. A `/help` the user sends shows,
    /// and refreshes `commands` too.
    public func loadCommands(in roomID: String) async {
        guard connection != nil, status == .signedIn, let asker = commandsAsker, commandsAskedAs != asker else { return }
        commandsAskedAs = asker
        commandsNoticeAwaited = roomID
        let params: JSONValue = ["room_id": .string(roomID), "body": ["text": "/help", "format": "plain"]]
        do {
            _ = try await request("command", params)
        } catch {
            if connectionNumber == asker.connection, commandsNoticeAwaited == roomID { commandsNoticeAwaited = nil }
        }
    }

    private struct CommandsAsker: Equatable {
        var connection: Int
        var userID: String
        var roles: [String]
    }

    private var commandsAsker: CommandsAsker? {
        guard let you else { return nil }
        return CommandsAsker(connection: connectionNumber, userID: you.userID, roles: you.roles.sorted())
    }

    /// Composer text as §4.1 reads it. Without capability `command` every text is a message as
    /// written, as apron-web's `composerAction`.
    public struct Draft: Hashable, Sendable {
        /// The text to send: a `//` message loses its first slash.
        public var text: String
        public var isCommand: Bool

        public init(text: String, commands: Bool = true) {
            if !commands {
                self.text = text
                isCommand = false
            } else if text.hasPrefix("//") {
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
        /// The `link` embeds built for its links (`DraftLinkPreviews`), sent before the uploads.
        public var links: [Embed] = []
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
    public func post(_ text: String, in roomID: String, replyTo: LogID? = nil, mentions: [String] = [], links: [Embed] = [],
                     attachments: [Attachment] = []) {
        outbox.append(PendingMessage(id: "q-" + environment.makeRequestID(), roomID: roomID, text: text, replyTo: replyTo,
                                     mentions: mentions, links: links, attachments: attachments, userID: you?.userID, queuedAt: Date(), state: .sending))
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
                try await send(item.text, in: item.roomID, replyTo: item.replyTo, mentions: item.mentions, links: item.links,
                               attachments: item.attachments, id: item.id)
                outbox.removeAll { $0.id == item.id }
            } catch let error as RPCError {
                if error.retryAfter != nil, error.limitCategory == "upload" {
                    // Only uploads are paused, for as long as a day: the text behind it goes on.
                    mark(item.id, .failed(error.message.isEmpty ? "This server takes no more uploads for now." : error.message))
                } else if let wait = error.retryAfter {
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

    /// Saves an edit: the new text and who it mentions, and the embeds and reply it keeps,
    /// sending every other client field again (§4.4). A save replaces `body.mentions`, and the
    /// server notifies only the users it adds (§3.5.5).
    public func edit(_ edit: MessageEdit, text: String, mentions: [String]) async throws {
        try require("edit")
        _ = try await request("message", .object(save(edit.saved(text: text, mentions: mentions), in: edit.message.roomID)))
    }

    /// Saves your message without its reply reference, as apron-web's Remove reply reference.
    public func removeReply(from message: MessageSnapshot) async throws {
        try require("edit")
        var snapshot = message
        snapshot.replyTo = nil
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
    /// (EXTENSIONS.md). Read from `you` only. Without the capability, what PROTOCOL.md allows, as
    /// apron-web's `CORE_PERMISSIONS`: any member may ask to add others to any room (§4.2.2), and
    /// the server's refusal shows.
    public var permissions: Permissions {
        guard server?.has("ext:permissions") == true else { return Permissions.core }
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
        arrivals.mine(roomID)
        _ = try await request("room_join", ["room_id": .string(roomID)])
    }

    public func leave(_ roomID: String) async throws {
        try require("rooms")
        _ = try await request("room_leave", ["room_id": .string(roomID)])
    }

    /// Creates a room, or a thread when `parentRoomID` is set (§4.2.4), its description left out
    /// when blank. A thread is never sent `private`: it takes its room's. A room asked for as
    /// private, or a thread of a private room, is checked once its record arrives: one the server
    /// made visible to others throws, and stays joined to leave. Returns its `room_id`.
    @discardableResult
    public func createRoom(title: String, description: String = "", parentRoomID: String? = nil, isPrivate: Bool = false) async throws -> String? {
        var params: [String: JSONValue] = ["title": .string(title)]
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { params["description"] = .string(description) }
        if let parentRoomID { params["parent_room_id"] = .string(parentRoomID) }
        if isPrivate, parentRoomID == nil { params["private"] = true }
        let roomID: String
        do {
            roomID = try await createRoom(params)
        } catch let error as RPCError where error.code == RPCError.Code.unsupported && isPrivate && parentRoomID == nil {
            throw PrivateRoomError.noPrivateRoomsUncheck
        }
        let checks = parentRoomID.map(self.isPrivate) ?? isPrivate
        guard checks else { return roomID }
        guard let room = await record(of: roomID) else { throw PrivateRoomError.neverArrived }
        if room.isPrivate != true {
            throw parentRoomID == nil ? PrivateRoomError.notPrivate(title: title.nilIfEmpty) : PrivateRoomError.threadNotPrivate
        }
        return roomID
    }

    /// The visible rooms this user has not joined (§4.2.1), installed as records, with their
    /// members, as apron-web lists them: Browse Rooms counts them (`memberTotal`).
    public func listUnjoinedRooms() async throws -> [String] {
        try require("rooms")
        let result = try await request("room_list", ["filter": "not_joined", "members": true])
        install(Records(roomListResult: result))
        return (result["not_joined"]?.arrayValue ?? []).compactMap { $0["room_id"]?.stringValue }
    }

    func require(_ capability: String) throws {
        guard server?.has(capability) == true else { throw Failure.unsupported(capability: capability) }
    }

    /// Sends a notification on the open connection, if there is one; nothing answers it.
    func notify(_ method: String, _ params: JSONValue) async {
        try? await connection?.notify(method, params: params)
    }

    func request(_ method: String, _ params: JSONValue, id: String? = nil) async throws -> JSONValue {
        guard let connection else { throw Failure.notConnected }
        guard status == .signedIn else { throw Failure.notSignedIn }
        if let held = heldBack(method, params) { throw held }
        do {
            return try await connection.request(method, params: params, id: id)
        } catch let error as RPCError {
            noteLimit(error, method: method, params: params)
            throw error
        }
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
    /// that moves sooner goes when the interval is up, as the newest then. Only an account's goes,
    /// as apron-web's since #187 (a guest's is dropped by the server), and none in a private room
    /// where Read Receipts are off and the server would show it (`withholdsRead`).
    public func markRead(_ roomID: String, through messageID: LogID) async {
        guard status == .signedIn, let server, connection != nil, you != nil else { return }
        advancePosition(roomID, to: messageID)
        guard server.has("activity"), readCursors[roomID].map({ $0 < messageID }) ?? true else { return }
        readCursors[roomID] = messageID
        guard server.keepsReadCursors, resumable, !withholdsRead(roomID), !cursorsWaiting.contains(roomID) else { return }
        if let last = cursorSentAt[roomID] {
            let wait = environment.readCursorInterval - (ContinuousClock.now - last)
            if wait > .zero {
                cursorsWaiting.insert(roomID)
                try? await Task.sleep(for: wait)
                cursorsWaiting.remove(roomID)
            }
        }
        guard status == .signedIn, let connection, let cursor = readCursors[roomID], !withholdsRead(roomID) else { return }
        cursorSentAt[roomID] = .now
        readSent[roomID] = cursor
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

    /// Loaded messages from others after `readThrough`, or all of them when nothing is known; in
    /// a room someone added you to, only those after your join (`joinFloor`).
    public func unreadCount(in roomID: String) -> Int {
        guard you != nil else { return 0 }
        let read = [readThrough(roomID), joinFloor(of: roomID)].compactMap { $0 }.max()
        return timeline(roomID).count { message in
            !isYou(message.from.userID) && read.map { $0 < message.messageID } ?? true
        }
    }

    /// Your latest join of a room someone added you to, as apron-web's `joinOf`: the `log_id` of
    /// the newest loaded membership record naming you, when it joins you. Nil for a room you
    /// joined yourself, or before that record loads.
    public func joinFloor(of roomID: String) -> LogID? {
        guard addedTo.contains(roomID) else { return nil }
        for record in store.membershipLog(of: roomID).reversed() {
            if let entry = record.entries.first(where: { isYou($0.user.userID) }) { return entry.joined ? record.logID : nil }
        }
        return nil
    }

    /// A room's title; a thread without one is "Untitled", an untitled private room is named for
    /// its members (`PeopleTitle`), and another room is its `room_id`.
    public func title(of roomID: String) -> String {
        if isUntitled(roomID) { return "Untitled" }
        if isNamedForMembers(roomID) { return membersTitle(roomID) }
        return TextDirection.withoutOverrides(store.room(roomID)?.title?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? roomID)
    }

    /// The joined rooms in the order kept on this device (`RoomOrder`; those not placed yet by
    /// title, after the rest), each with the threads known under it, most recently active
    /// first (`ThreadList.byActivity`). A joined thread whose parent the user has not joined
    /// stands on its own. `threadList(of:open:)` picks which of them the list shows.
    public var roomTree: [RoomNode] {
        let known = store.roomIDs.compactMap { store.room($0) }
        let topLevel = known.filter { room in
            joinedRoomIDs.contains(room.roomID) && room.parentRoomID.map { !joinedRoomIDs.contains($0) } ?? true
        }
        return tree(of: topLevel)
    }

    /// The rooms list's Rooms: `roomTree` without the top-level private rooms, which Private lists.
    public var publicRoomTree: [RoomNode] { roomTree.filter { !isPrivateRoom($0.roomID) } }

    /// The rooms list's Private: the joined top-level private rooms (§4.2.4), with their threads.
    public var privateRoomTree: [RoomNode] { roomTree.filter { isPrivateRoom($0.roomID) } }

    /// The room you are reading before joining, as the open room the rooms list shows under
    /// Other Rooms, as apron-web marks it open there (#192): `open` or the room of the thread
    /// `open` names, with its threads. Nil once joined, for a private room, or a thread whose
    /// room you have joined.
    public func readingNode(open: String?) -> RoomNode? {
        guard let record = open.flatMap(store.room) else { return nil }
        let room = record.parentRoomID.flatMap(store.room) ?? record
        guard room.parentRoomID == nil, !joinedRoomIDs.contains(room.roomID), !joinedRoomIDs.contains(record.roomID),
              room.isPrivate != true else { return nil }
        return tree(of: [room]).first
    }

    private func tree(of topLevel: [RoomRecord]) -> [RoomNode] {
        let known = store.roomIDs.compactMap { store.room($0) }
        let byTitle = topLevel.map(\.roomID).sorted { codePointLess(title(of: $0), title(of: $1)) }
        return RoomOrder.inOrder(byTitle, arrangementKey.map(roomArrangement.order) ?? []).map { roomID in
            let threads = known.filter { $0.parentRoomID == roomID }
                .map { ThreadList.Entry(id: $0.roomID, joined: false, activity: activity(of: $0.roomID), hasNews: false) }
                .sorted(by: ThreadList.byActivity)
            return RoomNode(roomID: roomID, threadIDs: threads.map(\.id))
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

    init(firstLogID: LogID?, more: Bool) {
        self.firstLogID = firstLogID
        self.more = more
    }

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

    /// What a `retry_after` holds back (`data.ext.limits`, extension `ext:limits`): `read`,
    /// `write` or `upload`, or nil when it names none.
    var limitCategory: String? { data?["ext"]?["limits"]?.stringValue }
}

/// Resumes a continuation once, for whichever of the tasks racing to it comes first.
private final class FirstOf: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume() {
        continuation.withLock { $0.take() }?.resume()
    }
}
