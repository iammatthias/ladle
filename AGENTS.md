# Ladle, agent notes

Ladle is a native iOS client for the Apron chat protocol v9. Apron is the protocol; Ladle is the
client. Single-user: one identity per server, with several servers. Swift 6, SwiftUI, Apple frameworks only. Phase 1 is the scaffold and the
protocol core behind the protocol's client conformance fixtures. Phase 2 adds the session layer
(`ServerSession`, `SessionStore`) and a thin SwiftUI client over it.

The spec is `PROTOCOL.md` in the protocol repository, checked out read-only at
`/Users/iammatthias/Developer/forks/apron-server-go/testdata/apron`. Implement to the spec and
its fixtures, not to the TypeScript reference client (`.apron-web/src/lib/protocol/` in the same
clone), which is only a worked example.

## Layout

- `Packages/ApronKit/`: the protocol core as a local Swift package, free of UIKit and SwiftUI so
  `swift test` runs it on the Mac.
  - `JSONValue`: the hand-written JSON codec. Numbers keep their source text (IDs beyond 2^53
    round-trip), object keys are kept exactly (`"__proto__"` included), objects compare without
    key order. Foundation's JSON types do none of this; do not reintroduce them on the wire path.
  - `Envelope`: `Request`, `Response`, `WireNotification`, `RPCError`, `Frame`. Decoding ignores
    `jsonrpc` and unknown keys; outgoing frames omit `jsonrpc`. (`WireNotification`, not
    `Notification`, because `Foundation.Notification` makes the bare name ambiguous in every file
    that imports both.)
  - `LogID`: a validated decimal string compared numerically (`"9" < "10"`). `codePointLess` is the
    protocol's "string order"; never sort IDs or emoji with `String.<`.
  - `ServerInfo`: the typed `server` frame.
  - `Records` and `ReplayStore`: the four record stores (room records by `room_id`, message
    snapshots by `message_id`, reaction sets by `(message_id, user_id)`, memberships by
    `(room_id, user_id)`) under the replay rule, member-list seeding as of a position, re-homing
    on moves, and the README's logical projection. `ext` stays a `JSONValue`.
  - `Connection`: an actor over a `FrameTransport`. `connect()` returns the first `server` frame,
    `request` matches replies by `id`, `notifications` streams the rest, pings at `server.ping`.
    One writer task sends frames in call order; `send` queues a request and returns a `Reply` to
    await later, which is how `room_list` is pipelined behind `auth`. An upgrade refused with an
    HTTP status fails as `Failure.rejected(status:)`. `WebSocketTransport` is the URLSession
    implementation and sets the `Origin` header.
  - `ServerSession`: `@MainActor @Observable`, one per `ServerRecord`. Connection lifecycle,
    sign-in, the stores, and every chat operation. Its `Environment` is the test seam
    (transport factory, sleep, jitter, request IDs, proposal `state`, page size).
    - Sign-in is `SignIn`: `.token`, `.guest`, `.emailProposal`, `.emailCode`. A sign-in sends
      `auth` with `agent` and pipelines `room_list {filter: joined, members: true}` behind it.
      A token in any result replaces the saved one; a `.token` sign-in without one keeps the
      presented token; a guest result without one clears it. The email code goes on the
      connection that proposed (§4.11.2); `pendingEmail` is cleared on every disconnect.
    - Reconnect: pending requests fail with `Connection.Failure.closed` (no same-id resend),
      then `backoff(attempt:jitter:)` = min(60 s, 0.5 s × 2^min(7, attempt − 1)) × [0.8, 1.2),
      never below a `retry_after`. Attempts restart after 30 s signed in. An id-less `denied`
      or a refused upgrade stops reconnecting (`Status.stopped`). A resume answered `denied` or
      `invalid_params` clears the token and asks for sign-in.
    - History: `open` loads the newest page once (`limit` = page size, no bounds), `loadOlder`
      pages with `before = first_log_id − 1` until `more` is false or the floor
      (`history_log_id`, else `latest_log_id + 1`). Each opened room keeps a checkpoint that live
      records advance; after a reconnect it pages forward from `checkpoint + 1`.
    - Results can resume before the notifications sent ahead of them are applied, so code and
      tests wait for store state rather than assume it on return.
  - `SessionStore`: every server's session, the saved list, and account persistence.
  - `SignIn`, `TokenPayload` (a bare token or a §A.4 link with `token`), `UserDirectory` (one kept
    user object per `user_id`, merge rules, `Name (@user_id)` on clashes).
  - `ServerRecord`, `ServerStore`, `TokenStore`: the saved servers (JSON, no secrets) and the seam
    for the bearer token. `InMemoryTokenStore` is for tests.
- `Ladle/`: the app, views only; logic belongs in ApronKit where `swift test` reaches it.
  `Servers/` (list, editor), `SignIn/` (sheet, VisionKit QR scanner), `Rooms/`, `Timeline/`
  (messages, composer). `Servers/KeychainStore.swift` is the only place a secret is persisted
  (generic password, service `com.iammatthias.ladle.token`, account = server id).
- `LadleTests/`: hermetic app tests (no network, no server).
- `Packages/ApronKit/Tests/ApronKitIntegrationTests/`: `ServerSession` against the real Rust
  server. `Aprond` copies the binary to a temporary directory (its build tree may be rebuilding),
  starts it per test with `--store memory --email.enable --email.sender log` on a free loopback
  port, and reads email codes from stderr. The binary defaults to the sibling
  `apron-server-rust/target/release/aprond`; `APROND` overrides it.
- `Config/Domains.example.xcconfig`: template for the gitignored `Config/Domains.xcconfig`.
- `scripts/sync-fixtures.sh`: copies the protocol's replay fixtures into the package's test
  resources; `--check` fails on drift.

## Build and test

- `Ladle.xcodeproj` is generated by XcodeGen and gitignored. Edit `project.yml`, never the pbxproj.
- `./build.sh build` builds the `Ladle` scheme with DerivedData in `build/`. With no simulator
  it uses the generic iOS Simulator destination.
- `./build.sh test` runs the fixture drift check and then the `Ladle` scheme's tests on the
  "Ladle iPhone" simulator (create it once with `xcrun simctl create "Ladle iPhone" <iPhone
  device type> <iOS runtime>`). Set `DEST` to override.
- The gate is `scripts/sync-fixtures.sh --check && swift test --package-path
  Packages/ApronKit`. It checks the fixture copies against the spec clone, then runs the fixture
  gate below, the unit tests, and the integration tests. It needs no simulator. The integration
  tests skip when `aprond` is missing; set `APRON_REQUIRE_SERVER=1` to make that a failure.
- aprond has no page-size flag; the paging test passes `limit` through the session's page size.
- Deployment target is iOS 27.1 because the newest installed SDK is iOS 27.1 (Xcode 27.1); a
  target cannot be newer than its SDK. Bump to 27.2 in `project.yml` and `Package.swift` once
  Xcode ships that SDK.

## Conformance fixture gate

`ReplayFixtureTests` runs every file in `Packages/ApronKit/Tests/ApronKitTests/Fixtures/wire/
replay/`, every variant twice (literal frames, and with `"jsonrpc":"2.0"` added to each frame),
checking each `expect` step and the final `expected` projection. Currently 18 files, 42 variants,
84 runs; the aggregate test pins those counts, so bump them when fixtures are added upstream.
The fixtures are copies: `scripts/sync-fixtures.sh --check` fails when they drift from the
clone. Run it before `swift test` (the gate line above does), and `./build.sh test` runs it too. The session fixtures (`wire/session/`) are phase 2.

## Rules

- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.
  Shared state is an actor or a value type.
- Secrets live only in the Keychain through `TokenStore`. `ServerRecord` and `servers.json` never
  hold a token.
- `ServerRecord` is plain Codable persisted as JSON. Every field after `id` and `url` gets a
  default in `init(from:)`, so older files keep loading. Adding a non-optional field without a
  default breaks saved files.
- Apple frameworks only: Foundation, URLSession WebSockets, AuthenticationServices,
  Security, SwiftUI, Observation. A third-party package needs a justified entry here. None so far.
- Replay rule: a record replaces only on a numerically greater `log_id`, or a tombstone at an
  equal one; a room record without `log_id` always replaces; replacement is whole. Compare
  `log_id`s with `LogID`, never as strings.

## Identity and sign-in

The primary v1 sign-in is a bearer token (`scheme: "token"`, §3.2.1), pasted into the app or
scanned from a QR code, obtained from another client. This works today with no server changes:
the web client has a "sign in with a token the server gave you" mode, the public demo issues
tokens through `/invite-bot` (a bot identity), and the protocol allows a command that issues
more tokens; the owner's Rust server will add `/add-device` for the signed-in account.

Tokens are bound to the origin of the client that obtained them (§3.2.1, §4.10). So each
`ServerRecord` stores an `origin` (for example `https://web.apron.chat`), defaulted to
`https://<host>` of the server URL and editable by the user, and `WebSocketTransport` sends it as
the `Origin` header on the upgrade request. Apple's reserved-header list for URLSession is
Content-Length, Authorization, Connection, Host, Proxy-Authenticate, Proxy-Authorization, and
WWW-Authenticate; `Origin` is not on it
(https://developer.apple.com/documentation/foundation/nsurlrequest, "Reserved HTTP headers").
Apple does not state that a request-set `Origin` reaches the WebSocket handshake. Phase 2
confirmed it on macOS: aprond admits an upgrade with no `Origin`, and refused
`URLSessionWebSocketTask`'s upgrade with 403 when the record's origin was
`https://evil.example` (`testTheServerSeesTheOriginHeader`). Not yet confirmed on a device.

Fallbacks: email with a typed code (§4.11). Optional later paths, not implemented:

- An `ASWebAuthenticationSession` sheet for servers that host a sign-in page. Apple's
  documentation for the class
  (https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
  says nothing about passkeys or WebAuthn, and "Supporting passkeys" does not mention the
  session; the only web-view guidance there is for `WKWebView`, which needs the relying party as
  an associated domain. Treat "passkeys work inside the session for any domain" as unverified in
  Apple's docs; an Apple engineer's forum reply
  (https://developer.apple.com/forums/thread/738229) says WebAuthn in `WKWebView` is first-party
  only and points third-party sign-in at the session, which is suggestive, not documentation.
- Native passkeys with `ASAuthorizationPlatformPublicKeyCredentialProvider` for the owner's own
  domains. Constraints, from Apple's docs unless marked:
  - The app needs a `webcredentials:<domain>` associated domain, and the server must serve
    `https://<domain>/.well-known/apple-app-site-association` over https with a valid certificate
    and no redirects, listing `MP92RCAPRG.com.iammatthias.ladle` under `webcredentials.apps`
    (https://developer.apple.com/documentation/xcode/supporting-associated-domains). "You need to
    have an associated domain with the webcredentials service type when making a registration
    or assertion request; otherwise, the request returns an error"
    (https://developer.apple.com/documentation/authenticationservices/supporting-passkeys).
  - The platform puts `https://<rpID>` in `clientDataJSON` as the origin, where rpID is the
    `relyingPartyIdentifier` passed to the API, so the server's `--webauthn.origin` must include
    it. Source: an Apple Systems Engineer's reply, not a documentation page
    (https://developer.apple.com/forums/thread/719003). The association file supports no custom
    ports (https://developer.apple.com/forums/thread/735218, Apple engineer), so the origin
    carries none.
  - `localhost` cannot be an associated domain. Not found stated in Apple's docs; it follows
    from the file having to be served over https from a fully qualified domain.
  - The domains are the owner's private server names, so they live in the gitignored
    `Config/Domains.xcconfig` (`APRON_ASSOCIATED_DOMAINS`), with `Domains.example.xcconfig`
    committed. `ServerRecord.rpID` stays optional.
- Native push needs a §4.9.2 `relay` with APNs, which is out of scope for v1.

## Cleanup

- `build/` is DerivedData; delete it when a work session ends. `Packages/ApronKit/.build/` is
  SwiftPM's; both are gitignored.
- Delete simulators you create once a phase is done, except "Ladle iPhone", which later phases
  reuse.
- Never commit `Config/Domains.xcconfig`, a token, or the owner's personal identifiers. The team
  ID and bundle ID are fine.
- Commit on a branch with `git commit -F <file>`; never push from an agent session.
