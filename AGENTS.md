# Ladle, agent notes

Ladle is a native iOS client for the Apron chat protocol v9. Apron is the protocol; Ladle is the
client. Single-user: one identity per server, with several servers. Swift 6, SwiftUI, Apple frameworks only. Phase 1 is the scaffold and the
protocol core behind the protocol's client conformance fixtures. Phase 2 adds the session layer
(`ServerSession`, `SessionStore`) and a thin SwiftUI client over it.

The spec is `PROTOCOL.md` and `EXTENSIONS.md` in the protocol repository, cloned read-only at
`~/Developer/forks/apron-server-go/testdata/apron`, at the commit `scripts/SPEC` pins (read it
with `git show <pin>:PROTOCOL.md`; the clone's checkout may be older). Implement to the spec and
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
    on moves, and the README's logical projection. `ext` stays a `JSONValue`. It also logs every
    membership record (`membershipLog(of:)`, dropped below the retention floor) and every logged
    room record (`renames(of:)` reads their titles) it sees, superseded or not, for the
    timeline's lines and for what a kept log writes back.
  - `TextDirection`: what users write takes its direction from its first strong letter (§3.5.2).
    Names, room titles, descriptions, the server's title and message text show without
    U+202A–U+202E (stored and sent as written); a name or preview set among the app's own
    words is isolated (U+2068…U+2069); a message written against the app's direction starts
    at its own side (`written(in:)` in the app).
  - `CustomEmoji`, `EmojiCatalog`, `EmojiKeys` (EXTENSIONS.md `ext:emoji`): `ServerInfo.emojiCatalogURL`
    is `ext.emoji.catalog_url` under the capability, only `https:`, loopback `http:` or
    `data:application/json`. `EmojiCatalog` decodes entry by entry: a bad key, or a `url` that
    is not `http(s)` or an inline image drops the entry, a bad field drops alone; `ServerSession.emojiCatalog` is the fetched catalog `gated(by:)` the session's `MediaGate` (an emoji whose image may not load shows as its key and leaves the picker), and a catalog the gate refuses is not fetched until it allows it; `offered`
    leaves out `hidden` ones, by category then key (the catalog's order does not survive
    `JSONValue`), and `search` ranks name matches before `alt` and tag matches. `EmojiKeys`
    scans text left to right as the spec says; `MessageText` marks each key the catalog has
    outside code and links with `CustomEmojiKey`. `ServerSession.loadEmojiCatalog()` fetches
    the current URL's catalog once through `Environment.fetchEmojiCatalog`
    (`EmojiCatalogFetch.live`: no cookies, credentials or referrer, at most 4 MB), keeps it by
    URL, and never retries a failed URL; `emojiCatalog` is the current one. The recorded demo
    `server` frame and catalog are in `Tests/ApronKitTests/Fixtures/ext-emoji/`.
  - `ReactionEntry`: a `reactions` entry (§4.7) is one emoji sequence or a key, such as a custom
    emoji's `:name:`. Entries compare without U+FE0F (`key`): a set, the summaries and
    `toggleReaction` treat ❤ and ❤️ as one, and a summary shows the fully-qualified spelling.
  - `Connection`: an actor over a `FrameTransport`. `connect()` returns the first `server` frame,
    `request` matches replies by `id`, `notifications` streams the rest, pings at `server.ping`.
    One writer task sends frames in call order; `send` queues a request and returns a `Reply` to
    await later, which is how `room_list` is pipelined behind `auth`. An upgrade refused with an
    HTTP status fails as `Failure.rejected(status:)`. `WebSocketTransport` is the URLSession
    implementation and sets the `Origin` header.
  - `ServerSession`: `@MainActor @Observable`, one per `ServerRecord`. Connection lifecycle,
    sign-in, the stores, and every chat operation. Its `Environment` is the test seam
    (transport factory, sleep, jitter, request IDs, proposal `state`, page size).
    - Sign-in is `SignIn`: `.token`, `.signUp`, `.guest`, `.emailProposal`, `.emailCode`,
      `.externalProposal`, `.externalCode`, `.ownLink` (a link with this device's `state`) and
      `.link` (a confirmed link, sent as `token`, saved as method `link`). Passkeys and
      additions to an account are `ServerSession+SignInWays.swift` ("Identity and sign-in").
      `.signUp` is scheme `token` with a sign-up invite (`apron_join_`, Cloudflare's `/invite`)
      and the new account's `name`; its result carries the account's own `apron_invite_`
      token, which is saved in place of the invite. A sign-in sends
      `auth` with `agent` and pipelines `room_list {filter: joined, members: true}` behind it.
      A token in any result replaces the saved one; a `.token` sign-in without one keeps the
      presented token; a guest result without one clears it. The email code goes on the
      connection that proposed (§4.11.2); `pendingEmail` is cleared on every disconnect.
    - A `user` `you` whose `user_id` differs from this account's is a rename (§3.3.3: `you`
      replaces the connection's identity), as is a `new` with an `old` naming it. The saved
      `ServerRecord.account`, the `ReadPositionStore` entries and the queued messages move to
      the new id, `UserDirectory.rename` moves the kept object and makes the old id read as the
      new one (for others' `{new, old}` too), and `isYou` still counts the old id's logged
      messages as yours. A rename while offline cannot be told from another account.
    - `serverName` is the label the user gave the server, else its `title` (§3.1), else its
      host; the server list and rail show it with the host, and `serverAvatarURL` (the frame's
      `avatar` where avatars may load) in place of the initials.
    - `mayWrite`: false with `permissions.write == false` (EXTENSIONS.md `ext:permissions`), or
      for a guest (scheme `guest`) on a server from before EXTENSIONS.md whose `ext.settings`
      says `guest_posting: false`. The timeline then shows a sign-in prompt in place of the
      composer, and react, reply, edit, delete, move, join, leave and New Thread are off with
      the reason.
    - `permissions` is `Permissions`, `you.ext.permissions` under capability `ext:permissions`
      (EXTENSIONS.md): `write`, `add_members` and `move_any`, each defaulting when absent or not
      a boolean, and all of them when `permissions` is not an object.
      `edit` and `move` share one save that sends the message's `body`, `reply_to` and `ext` as stored (§4.4 replaces client fields); `edit` replaces the text and `body.mentions`, `move` adds the new `room_id`;
      `mayMove` allows your own messages, and anyone's with `move_any`. The message menu offers
      Move To the room's threads, or out of a thread to its room and that room's other threads.
    - Reconnect: pending requests fail with `Connection.Failure.closed` (no same-id resend),
      then `backoff(attempt:jitter:)` = min(60 s, 1 s × 2^min(6, attempt − 1)) × [0.5, 1.5) (Cloudflare's docs/limits.md checklist),
      never below a `retry_after`. Attempts restart after 30 s signed in. An id-less `denied`
      or a refused upgrade other than 429 or 5xx stops reconnecting (`Status.stopped`).
    - `ConnectionState` (`ConnectionState.swift`): a status as UX spec 4.1 shows it, its
      symbol, words, detail, and whether it is a problem with Try Now; nil when signed in.
    - Reconnect feedback (`PaneLoading.swift`), as apron-web's page and `SettleFlag`: `SettleFlag`
      (on after 400 ms, then at least 600 ms, and 300 ms after its source ends) is a value over
      passed-in times; `PaneLoading` turns `Input` (`reconnectingQuietly`, `isCatchingUp` for the
      room and the others, `isLoading`, thread or not) into `Shown` (the pill's words, the
      catching-up line, the older pill), quiet for 1.5 s from the start of a way back, and
      replays changes due before a late `update`. `PaneLoadingWatch` runs it on
      `Environment.now` and `sleep`, re-reading the session through `withObservationTracking`.
      `isCatchingUp` is a room opened before whose catch-up has not marked it live since signing
      in. `ownPresence` is the profile bar's dot: `unknown` (dashed) while not signed in.
    - Connection status (`ConnectionStatus.swift`): after an upgrade fails, before the server's
      greeting, `Connection.probe` sends one `GET <url as https>?apron_connection_status=1` with
      the record's Origin through `Environment.fetchConnectionStatus`. A reply with
      `Apron-Connection-Status: 1` and a JSON `error` sets `unavailableMessage` (server list row,
      rail tooltip, a Callout in the room view; cleared on the next connection) and its
      `Retry-After` seconds floor the next reconnect delay. Anything else falls back to plain
      backoff. `LiveProbeTests` runs against a real server when `APRON_LIVE_PROBE_URL` is set. A resume answered `denied` or
      `invalid_params` clears the token and asks for sign-in.
    - History: `open` loads the newest page once (`limit` = page size, no bounds), `loadOlder`
      pages with `before = first_log_id − 1` until `more` is false or the floor. The floor is
      the retention boundary (`history_log_id`, or `latest_log_id + 1` when it is null) from any
      room record or history result, kept in `ReplayStore` per room and never lowered; raising
      it drops the snapshots whose `log_id` is below it, with their reactions, and refuses late
      ones. Each opened room keeps a checkpoint that live records advance; after a reconnect it
      pages forward from `checkpoint + 1`. A second `open` while the first page loads waits for
      it. `reveal(_:in:)` pages back 200 changes at a time until the timeline holds a message a
      link names, the loaded history reaches past it, or the floor stops it, so the timeline
      stays one unbroken run. A page arriving after an older one leaves paging where it is.
      `page` asks the device first while a restored room's kept log reaches below what
      `store` shows (`keptCoverage`), then the server.
    - Threads: a thread's record is in its own log (§4.3.1), not its room's, so a member of the
      room who has not joined it learns of it from `room_update` `updated` while connected, and
      otherwise only from `room_list {parent_room_id, filter: not_joined}` (§4.2.1). `open` and
      each reconnect's catch-up send that listing for every opened room, as apron-web lists the
      active room's threads; threads of a room not yet opened show only once it is. `open` waits
      for that listing at most `Environment.threadsWait` (3 s, real time: `sleep` is released one
      call at a time in tests), and `held` names the rooms whose first page and listing are
      loading, which the timeline holds back so thread cards come with the messages.
    - Notices: one that comes before this connection signs in is a `welcome` (Appendix B.1);
      the next one replaces it, and a sign-in by code or one whose result has a `token` drops
      it (apron-web's `dropWelcomes`). One without `room_id` after sign-in takes the room on
      screen. `notices(in:)` adds the roomless ones to `firstRoom`, the rooms list's first.
    - `timeline` leaves deleted messages out, so the rows, day pills, grouping, the New line,
      unread and mention counts, room previews and thread cards never see one. The store and
      the projection keep the tombstones for the replay rule; a reply quoting one reads
      "Original message deleted". `readThrough` still counts this user's deleted messages.
    - Results can resume before the notifications sent ahead of them are applied, so code and
      tests wait for store state rather than assume it on return.
    - Reading, as apron-web's `readAction`, `markRead` and `readPositions`: `readCursors` keeps
      this user's own `read_message_id` per room, from `activity` (§4.6) or this device's own
      mark, forward only.
      `readPositions` is how far this user read each room on this device, from a
      `ReadPositionStore` (`read-positions.json` beside `servers.json`, by server, account and
      room; in memory for tests and previews). `readThrough(_:)` is the furthest of the two and
      this user's newest loaded message; `unreadCount(in:)` counts loaded messages from others
      after it, all of them when nothing is known. `markRead(_:through:)` moves the position,
      and with capability `activity` the cursor, sending the frame unless `ext:settings` says
      `read_cursors: false` (`ServerInfo.keepsReadCursors`), at most once per room every
      `readCursorInterval` (5 s), the newest cursor going when the interval is up. The timeline calls it when the
      pane is on screen in the active app, at the bottom and loaded.
      A room opens at its latest message. apron-web's `landAtDivider` opens at the New line
      (pages back up to `DIVIDER_PAGES`, then `until(..., JUMP_WAIT_MS)` waits for the divider
      to render before scrolling to it); Ladle does not yet, because that scroll needs
      on-device verification, and the Simulator does not run here.
    - Commands: no server lists its commands in the `server` frame, so `loadCommands(in:)`
      sends `/help` when the composer first shows a command word, once per connection, and
      again only when `you`'s `user_id` or roles change; `commands` keeps the last list across
      reconnects. Both reference servers send `/help`'s `~private` notice before the `{}`
      result (§1), and a result can resume before its notice is applied, so the session does
      not tie the notice to the result: the first notice in the asked room that `CommandHelp`
      reads as a list is the answer, and stays out of `notices`. A `/help` the user
      types shows, and refreshes `commands`. A failed request is not retried on that connection.
  - `CommandHelp`: the one reader of `/help`'s text (`` - `<usage>`: <summary> `` per line,
    every line, from `~private` only), so a structured form (shazow/apron#85) can replace it
    here; `query(in:)` is the command word a draft is typing (after `/`, not `//`, before any
    space).
  - `SessionStore`: every server's session, the saved list, and account persistence.
  - Uploads (§4.8.3, §4.8.4, §4.8.6), as apron-web does them. `Embed` parses an embed once;
    its `upload` is pending until `url`, then an image, video or audio from `og`, or a file.
    `MediaGate` (`MediaGate.swift`) is the one place a media URL is decided, as apron-web's
    `mediaGate`: `decide(url, for: .timeline | .avatar)` gives `.load`, `.ask(MediaAsk)` or
    `.hidden` from the server's own HTTP origin (from its WebSocket URL), the origins `ext:media`
    names, small `data:image` URLs (always), and the viewer's `MediaSettings`
    (`MediaSettings.swift`: policy `trusted` or `any`, trusted sites global across servers,
    parsed as apron-web's `parseMediaOrigins`, kept in `media-settings.json` beside
    `servers.json`; Load's URLs for this launch). Under `trusted`, timeline media elsewhere asks,
    and avatars and custom emoji elsewhere are hidden; under `any`, avatars and emoji elsewhere
    load over `https:` only. `SessionStore` owns one `MediaSettings` and hands it to every
    `ServerSession`, whose `mediaGate` reads it, so views follow a change at once. `MediaLimits` reads `ext:media` (EXTENSIONS.md): `upload`, `avatar` and `emoji`,
    each file taking the limits of its most specific pattern alone. Without the capability a
    413 or 415 on the write decides. `UploadPlan.decide` says what a file
    needs to fit the `upload` category: nothing, a still image re-encoded (JPEG, else PNG where
    the server takes no JPEG) within 2048 px (or `max_side`) and 5 MB (or `max_bytes`), which
    drops its metadata, location included, a sound re-encoded as AAC `audio/mp4` at the
    `AudioEncoding` step that fits, a video exported as `video/mp4` or `video/quicktime`, or a
    refusal that names the limit. A server that takes no video (Cloudflare's demo takes images
    and audio) refuses videos; no poster frame is sent in their place. `UploadOffer` is what the
    attach menu offers and the pickers show. `AttachmentPreparer` carries out the image plans
    (ImageIO, so `swift test` covers it) and `MediaCompression` in the app the sound and video
    ones (AVFoundation). `prepareAvatar` crops the middle square at 512 px within the `avatar`
    category.
  - `send` posts a message or command as `format: "markdown"`, as apron-web's composer does, so what a
    user types renders the same in every client; the hidden `/help` stays `plain`.
  - `send` and `post` take attachments as `upload` embeds; `ServerSession+Uploads` writes each
    to the `write_url` the result lists, in request order, through `Environment.writeEmbed`
    (`EmbedWriter.live`, a URLSession `PUT`), and keeps `uploadProgress` by `embed_id`. A
    failed write comes back as a Not sent outbox item holding the file: the write URL was
    single-use and the server drops the embed, so Retry posts the file in a message of its own.
  - `PreviewServer` and `PreviewFixtures`: an in-memory server that answers from a script, and a
    two-server world built on it (rooms, threads, unread rooms, replies, reactions, an edit, a
    deleted message, presence). The design screenshots render from it; `PreviewFixturesTests`
    pins what it holds. It sends the script's `statuses` after `auth` (the design room is muted)
    and echoes a `status` mute back, as servers do; it refuses the `⏳` reaction for 45 s
    (`write`) and any new upload for two hours (`upload`), for the waits shot. The demo sends a welcome before `auth` and gives its guest no token, so the welcome stays in its first room, help. A `room_set` without a
    `room_id` creates the room (`new_1`, …) with you its one member. Home's private rooms: Ada's
    untitled conversation from its start (`directRoomID`), Bram and Chiara's (`groupRoomID`), Launch
    plan (`addedRoomID`) and ops, 4 of a limit of 5. Ops holds `/invite-device add phone`'s
    `~private` notice word for word (`inviteDeviceNotice`), with a made-up token. Message ids are server-wide, so no two rooms share a minute in the
    script.
  - `MessageText`: a body as apron-web renders it (§3.5, §3.5.2): `blocks` gives `MessageBlock`s
    (`MessageBlocks.swift`). `markdown` is Foundation's full CommonMark and GFM parse (no
    package), its soft breaks made hard (markdown-it's `breaks: true`), read into paragraphs,
    headings, quotes, lists, code blocks, rules, tables (`MessageTable`, rows padded) and each
    markdown image as `MessageImage` (a linked image stays its link; an image on another scheme
    stays its alt text); raw HTML stays text. `plain` is one paragraph. Each block's text then gets
    bare `http(s)` URLs and `apron:?` links linked in either format outside code and existing
    links, with apron-web's trimming of trailing punctuation; links on schemes apron-web's
    sanitizer refuses are dropped. Web links open in the default browser (`OpenURLAction`'s
    system action); Apron links open in the app (`ApronLink`). `attributed` is the blocks flattened, a line each, for reading links and code; the app draws blocks with `MessageBlocksView`. Neither reference server describes links:
    both drop a sender's `og`, so a `link` embed arrives as its kind and URL and shows the
    fallback card, as on the web. With `rooms`, a `#room_id` (Appendix A.3: not after a letter
    or digit, apron-web's `TEXT_ID`) outside code and links that names a room the session holds
    a record of (`ServerSession.referencedTitle`) shows as `#title` linked to `apron:?room=<id>`
    and marked `RoomReferenceKey`; the app draws it as a denim chip, and a tap opens the room
    through the link routing. `#doesnotexist` stays text.
    With `links` (`ServerSession.linkChip`, `LinkChips.swift`, apron-web #119), an Apron link
    written as its own URL (bare or `<…>`, its text the link percent-decoded) outside code
    becomes a `LinkChip` that says what it is: "Message" + " in #general", a room's title or
    its `room_id`, a thread's title + " in #general", a known user as `@name` (marked
    `MentionKey`), and on another server its host + " · Message" or " · Room", nothing looked
    up. The run keeps the link as written; label and detail carry `LinkChipKey`. A link with
    its own words, a token, an unknown key, or an unknown or other-server user stays a link.
    The app's `LinkChipText` adds the icon and `LinkChipRenderer` (a `TextRenderer`) draws the
    denim-soft ground or another server's outline; `MessageRowModel` reads each chip's words.
  - `DraftField` (`DraftField.swift`): what the composer writes, a new message, a reply or an
    edit (the composer's edit mode, Ladle's message editor), as apron-web's `DraftField`
    (#159). `query` is what the end of the text types: a `/` command word (outside an edit),
    an `@` word, a `:` shortcode (`StandardEmoji.query(in:)`), or a `#` room id.
    `ServerSession.suggestions(for:in:)` is the one list it shows; the `insert` methods put a
    pick in place of what was typed. A mention is `@Name` in the text and an entry in
    `mentions`; `sentMentions` are those the text still shows. An edit opens with the
    message's mentions whose `@name` or `@user_id` its text shows, and saves `body.mentions`
    from the field (§3.5.5, §4.4: a save replaces it). `ServerSession.submit` takes a
    `ComposerDraft` and runs a command, posts, or saves the edit. A reply names its message by `LogID` alone, as
    apron-web's kept `reply`; the composer shows what the session holds of it.
  - `StandardEmoji` (`StandardEmoji.swift`, generated `StandardEmojiData.swift`), as apron-web's
    `emoji-autocomplete.ts`: `query(in:)` is the `:shortcode` the text ends with (2 to 32 of
    `[A-Za-z0-9_+-]` after a `:` that starts a word); `search` ranks @emoji-mart/data's emoji
    by shortcode, whole term, a term's start, then anywhere, ties in the table's order (ICU's,
    as `localeCompare`), 8 at most; `suggestions` puts the catalog's matches first
    (`EmojiSuggestion`: a glyph or a custom emoji's key to insert). `tools/design/emoji.py`
    writes the table from the clone's `node_modules`, at the version and SHA-256 pinned in
    `tools/design/UPSTREAM`.
  - `SuggestionCursor` (`SuggestionCursor.swift`): the highlighted row of every list above the
    composer and the hardware keys over it, as apron-web's `DraftField.keydown`: ↑ ↓ wrap,
    Tab and Return pick, Escape puts the list away until the text changes; a list of another
    kind starts at its top.
  - `ComposerCommands` (`ComposerCommands.swift`), as apron-web's `commands.ts` and `sendMessage`:
    `ComposerAction` reads composer text (§4.1; every text a message without capability
    `command`, and `ServerSession.Draft` likewise for what `send` gets): `/nick`, `/join`,
    `/leave`, `/topic`, `/kick`, `/invite` as `me`, `room_join`, `room_leave`, `room_set`
    (title kept) and `room_leave`/`room_join` with `user_id`, a lone user read as Appendix A.3
    or exactly as a picked `@Name`; the rest a `command`. `action(for:withFiles:)` applies the
    server's capabilities (files go only with a message or the server's command). `run` does
    it: `/join` resolves an id or title (`join(named:)`) and returns the room to show, `/leave`
    from the thread you are in returns its room, an `unsupported` kick or invite goes to the
    server as typed. A failure appends a `~private` notice with `errorText` (`ErrorText.swift`,
    the app's words for every session error) and throws `CommandFailure` with the draft, which
    `TimelineView` gives back through `Drafts.restore` (only to an empty slot, as apron-web's
    `PaneDrafts.restore`).
  - `Drafts` (`Drafts.swift`): every room's and thread's `ComposerDraft` (a `DraftField` and its
    `StagedFile`s) by `DraftKey` (server id, `room_id`), as apron-web's `PaneDrafts`, owned by
    `SessionStore`. `FileDraftStore` keeps text, mentions, `reply_to` and ready files in
    `drafts.json` beside `servers.json`, each file's path relative to `staging` (`Staged` beside
    it, excluded from backup), since the container moves between launches; a missing or damaged
    field takes its default. An edit is never kept, nor a file still being fitted.
    `pruneStaging()` runs at launch and removes every staged folder no draft holds (the outbox
    does not outlive a launch); `removeAll(server:)` goes with the server.
  - `RoleMentions` (`RoleMentions.swift`): `@&role`, as apron-web #181. `roles(of:you:roles:)`
    is apron-web's `roomRoles` (others' latest roles that read as one ID, most held first, then
    by name), `ServerSession.mentionableRoles(in:)` over the room's members; `search` puts the
    exact role first; `written(in:)` finds each `@&<id>` not after a letter or digit.
    `ServerSession.mentionSuggestions` merges people and roles as apron-web's `matching` (8 rows,
    roles keeping 3, `@&` roles alone) into `DraftSuggestions.mentions`. `DraftField.insert(role:)`
    writes `@&role `, and `sentMentions(holders:)` lists mentions in the order the text names
    them, a role's holders where it stands, each once; `submit` passes the room's holders.
    `MessageText` marks `@&role` outside code and links as `RoleMentionKey` reading `@role`
    before it marks users; `plain` reads it `@role` too. Mention-of-you stays `body.mentions` only.
  - `RoomMentions`: the composer's `#` list, as apron-web's `room-autocomplete.ts`: `query(in:)`
    is the `#` word being typed (`[A-Za-z0-9_.-]`, at least one), `search` ranks exact, prefix,
    then contains on id and title, 8 at most, over `ServerSession.roomSuggestions` (every room
    and thread with a record), and `insert` puts `#room_id ` in the draft, which is what is sent.
  - Typing (`ServerSession+Typing.swift`, §4.6), as apron-web's `sendTyping` and
    `handleActivity`: `composerChanged(in:)` sends `activity {typing: 15}` with capability
    `activity` while signed in and allowed to write, again no sooner than `TypingTimes.refresh`
    (12 s), and `typing: 0` after `idle` (5 s) untouched; a message clears it without a `0`.
    Others' typing is `typing` by room, in the order last started or refreshed, without you
    (the server relays to your other devices too), held `min(seconds, longest)` (300 s), ended
    by `0` or their next message there, and forgotten on disconnect. `TypingLine` words it: the
    wide line ("Several people are typing…") and the phone subtitle ("3 people are typing…").
  - `Timeline` (`Timeline.swift`): what a room's timeline shows, in order (`TimelineItem`: day
    pills, messages, the New line, thread cards at the thread's creation position, join and
    leave lines and rename lines at their `log_id`s, as apron-web's `buildRoomTimeline`, and queued
    messages), mention counts, member sections (`MemberSection`, as apron-web's `byStatus` and
    `memberSections`: online, idle, dnd, unknown, offline, then none, by name within; Online is
    everyone not offline; one Members list without presence), `memberTotal` and `memberListNote`
    (a truncated listing's `member_count`, §4.2.1, which `ReplayStore.memberCount(of:)` keeps from
    the latest `members` listing),
    `Presence` (§4.5.1), `MediaItem`s for the media viewer, and the `MessageSnapshot` reads
    the views use (`date`, `isEdited`, `plainText`, `mentionIDs`).
  - Threads (`Threads.swift`), as apron-web's ThreadList and Start thread: `ThreadStart` suggests a
    thread's title (first line, 60 code points, else "Thread") and description (the text quoted,
    about 500 code points, fences closed, plain text escaped) from a message; `startThread`
    creates it (`createRoom` with a description) and remembers the message, and
    `thread(startedFrom:in:)` finds one already started (or loaded from its start replying to it).
    `roomTree` lists every known thread under its room by `activity(of:)` (newest loaded message,
    `latest_log_id`, creation); `threadList(of:open:)` (`ThreadList`) picks what the rooms list
    shows: under the open room its joined threads, Inactive (apron-web #185: past the newest
    five, quiet three days to the hour, no news; the open thread keeps the side it was opened on)
    and Other Threads (three, "N more…"), elsewhere only joined threads with news. `LastActive` words "4d", "9w", "2y"; `replyWords` "12+ replies";
    `title(of:)` is "Untitled" for a thread without a title (`isUntitled`).
  - The room header (`RoomHeader.swift`, `HiddenDescriptions.swift`), as apron-web's RoomHeader and
    RoomEditor: `headerLine` is the subtitle under the bar ("Link copied", typing on a phone,
    "12+ replies", or a put-away description's first line); `editRoom` sends `room_set` with
    `room_id` and both fields, an emptied one left out (a save replaces every client field);
    `mayEdit` is `rooms` and `mayWrite`, the server deciding the rest; `link(to:)` is Copy Link's
    web link; `markAllRead` reads a room through `readMark(of:)`. `HiddenDescriptions`, owned by
    `SessionStore` (`hidden-descriptions.json`, newest 200, dropped with the server), keeps each
    description put away by `DraftKey` as apron-web's FNV-1a fingerprint, so an edit pins it again.
  - `FloatingDay` and `DayLabel` (`FloatingDay.swift`): apron-web's FloatingDay and `dayLabelOf`:
    the day of the first message in view, none while its own pill shows above it, held
    `shownFor` (1.2 s) after scrolling stops. `MentionPulse` (`MentionPulse.swift`): apron-web's
    `MentionTracker` ping: the first feed is the room as shown (its newest log position the
    watermark); after it, a message logged past the watermark that newly mentions you (not your
    own) pulses, for `held` (1.2 s).
  - `MembershipLines` (`MembershipLines.swift`): apron-web's `membership.ts` (#170).
    `MembershipRecord.isBaseline` is 21 joins or more at once; `net` comes to who joined and left
    over a run, per user from their first entry to their last; `list` and `summary` word it ("Ada,
    Bob, and 4 others joined · Carol left"); `rename` words a title change.
  - `MessageRowModel` (`MessageRowModel.swift`): what a message's row shows, worked out once:
    the text, mentions marked `MentionKey` (`MessageText.attributed(…mentions:you:)`: each
    mentioned user's `@name` or `@user_id` outside links) for the app to draw as chips,
    whether it mentions you, the place cards, the embeds a card does not already show, the
    link to fetch a preview for and the `link` embed it replaces, and what VoiceOver reads.
  - `MessageMenu` and `NoticeMenu` (`MessageMenu.swift`): what a message's and a notice's
    menus offer as the session allows it, and the line over a notice. `signInLinks` are a
    `~private` notice's links that `ApronLink` reads with a token, as written, for Show QR Code.
  - `CodeHighlighter` (`CodeHighlighter.swift`, `CodeGrammars.swift`): apron-web's `highlight.ts`
    (#16) without highlight.js. `language(of:)` reads a fence through the web's aliases into its
    32 languages; `highlighted(_:fence:)` marks each run with `CodeTokenKey` (`CodeToken`:
    apron.css's colour groups), or is nil (plain) for no language, an unknown one or over 20,000
    characters, as on the web. One table-driven scanner (`Grammar`: comments, quotes, word lists,
    sigils, keys) covers most languages; diff, shell sessions, Markdown, XML and CSS/SCSS scan on
    their own. An unclosed string or comment ends at its line or the end. 500 results are kept.
    `MessageBlocksView` colours the runs from the theme.
  - `MessageText.plain` and `snippet` (`MessageText+Plain.swift`): a body as plain text for where it
    is not rendered, as apron-web's `plainTextOf` and `messageSnippet`: a `markdown` body without
    its syntax (code keeps its text, a link shows its text, each block a line, typed line breaks
    kept, mentions as written), cut to a line count and length. The reply quote and every
    one-line preview (`previewText`) use it.
  - `MessageLog` (`MessageLog.swift`): apron-web's `messageLog` (#164, #168, #172), messages as a
    Markdown log for the pasteboard: a quote per sender's run, dated and timed by `message_id`
    in the `Options.calendar`'s locale and time zone, reply lines, reactions, `_(N messages
    omitted)_` gaps against `order`, and uploaded images. apron-web's HTML copy is not ported:
    the app puts the Markdown on the pasteboard as text.
  - Select mode (`MessageSelection.swift`, `ServerSession+Selection.swift`), as apron-web's
    `selection.svelte.ts` (#14, #54, #95): `MessageSelection` is the picked ids in one pane
    (`toggle` with `rangeBetween`, `fillBetween` as `spanOf`, `earliest`, `denied`).
    `ServerSession.move(_:to:)` sends someone else's picked message first, alone, and nothing
    more if it is refused; the rest go one by one, those refused staying picked; into a thread
    it then adds the moved messages' authors (`room_join` with `user_id`) who aren't you, `~` or
    members, where `mayAddMembers` allows. `moveToNewThread` checks `mayMoveAll` before
    `createRoom`. `markdownLog(of:in:)` is Copy's `MessageLog` with the room's timeline as
    `order`, names from the directory and each reaction's reactors.
  - `PlaceCard` (`PlaceCards.swift`): the card for an Apron link to a message, room or thread in
    a message's text, as apron-web's LinkCard, drawn only from what the device holds:
    `ServerSession.placeCards(in:sessions:)` reads each link (relative ones against the sender's
    server, §5), takes another saved server's place from its session while it is signed in
    (`SessionStore.liveSession(for:)`), and gives at most 3, one per place, none for the message
    itself, a user, or a place the user can't see (no room record, or private and not joined).
    A loaded message still in the linked room shows its sender, room and three lines; anything
    else shows as its room: title, lock, member count. Nothing is fetched for a card: no request
    names one message, and `reveal` pages history. `PlaceCard.previews` is apron-web's
    `previewedByCard` (#155): an embed whose `url` reads as the same place as a card is hidden.
  - `LinkPreviews`: previews this device fetches for links the server did not describe (the
    user's choice over §4.8.1's "clients don't fetch third-party pages"). `unfurlURL` picks one
    link per message, the first `mayFetch` allows among its first three (text links, then `link`
    embeds without `og`), and none once any embed carries the server's `og`. `mayFetch` allows
    only `http(s)`, and refuses `link.apron.chat`, `localhost`, `.local` and single-label
    names, and non-public address literals; a public name that redirects inward is not caught. Previews are
    cached in memory and as JSON in `Caches/LinkPreviews` (7 days, 1 day for a failure; the
    fetch time is in the file, not its timestamp), with at most 3 fetches at once.
  - `ApronLink` (link.apron.chat SPEC §1, §2, §4, §5): the one reader and writer of Apron links.
    It reads the web form's fragment, then a link.apron.chat query's keys, and the `apron:?`
    URI; first value wins, unknown keys are kept for writers, `room` and `user` must be opaque
    IDs, `message` a `LogID` with a `room`, `server` `wss` or a loopback `ws`. A credential
    (`token`, `state`) comes only from a web fragment; one in the query refuses the link, one
    in an `apron:` URI is dropped. `webURL` writes the web form, never with a credential, and
    `resolved(against:)` makes a relative link absolute. apron-web's `preferences` key (#184) is its own page address, not a SPEC key: a link
    naming only it is no link, and beside a place it stays in `otherKeys` (`PreferencesSection`).
  - `LinkRoute` (`LinkRoute.swift`): where an Apron link that reaches the app, or a tapped
    reminder, goes: a saved server's sign-in sheet with the link's token, a place on a saved
    server, or the Connect sheet for the link's server; nowhere for a relative link.
  - `SignIn`, `TokenPayload` (a bare token or a sign-in link read by `ApronLink`), `SignInFill` (what a
    scanned or pasted sign-in fills in: server and token when adding a server, the token alone
    otherwise, or the other server a saved server's link names), `UserDirectory` (one kept
    user object per `user_id`, merge rules, `Name (@user_id)` on clashes).
  - `ConnectForm` (`ConnectForm.swift`): the Connect sheet's form: the address (the origin
    follows it until edited), name and origin, the methods the server offers, a scanned,
    pasted or tapped sign-in filling it in, the submit button's word, the `SignIn` to send,
    and the record to save (`SessionStore.save` adds it or saves changes).
  - `ServerRecord`, `ServerStore`, `TokenStore`, `ReadPositionStore`: the saved servers (JSON, no
    secrets), the seam for the bearer token, and the read positions. The in-memory stores are
    for tests.
  - Kept history (`KeptHistory.swift`, `ServerSession+History.swift`, `Archive.swift`,
    `LogEntry.swift`), as apron-web's `history-keeper.ts` and `session-cache.ts` (#56, #137) in
    one file: `History/<server id>.jsonl` beside `servers.json` (`FileHistoryFiles`, excluded
    from backup), only while `resumable`, one account per server. The file is an archive
    (`Archive`, apron-web's ARCHIVE.md: header, listing, one record per line in `log_id` order;
    keys in code point order, where the web writes them as received) whose header carries
    `ladle_kept.rooms`, each opened room's `KeptSync` (checkpoint, where its kept run starts,
    whether the server has older, floor, when it was last caught up). `ServerSession.kept` is a
    second `ReplayStore` that every `install` also applies, so it holds `store` and what the
    device keeps below it; it is what is written, two seconds after a change and in `suspend`.
    `HistoryRetention` is apron-web's `RETENTIONS` (30 days by default; `off` keeps a day, 150 per
    room, as the web's kept view) and `HistorySettings` keeps the choice in
    `history-settings.json`; `SessionStore.setRetention` rewrites every server's at once.
    `KeptRestore` plans a launch as apron-web's `restoredState`: a room not caught up since the
    cutoff starts over, a kept run starts no lower than the cutoff (by `log_id` where positions
    are times, `LogID.isTimeLike`), and the newest 50 entries show (`KeptRestore.window`).
    `start` reads it off the main actor and `adopt`s it before `run` resumes the token, so the
    sign-in's catch-up goes on from each kept checkpoint. `forgetKept` deletes it on sign-out,
    a refused token, another account (`resetChatState`) and server removal.
    `ReplayStore.logEntries(of:)` is a room's log as `LogEntry`s, and `LogEntry.slice` is
    apron-web's `sliceLog`.
  - Export and archive (`Archive.swift`, `ArchiveServer.swift`, `ServerSession+Archive.swift`), as
    apron-web's `archive.ts`, `archive-server.ts` and `/archive` (#135, #171):
    `ServerSession.exportArchive(includingPrivate:)` writes what `kept` holds, each opened room
    from where its stretch starts, the rest listed with `history_log_id: null`; without private
    rooms (#171) it leaves them, their threads, their records and anyone known only from them out
    (`ArchiveSource.hiddenRooms`). `Archive.fileName` is `apron-<host>-<day>.jsonl` in UTC.
    `ArchiveServer` is a `FrameTransport` serving one `Archive` read-only (guest only,
    `ext:permissions` `write: false`, `ext:archive` with the header, `ext:media` only
    `withImages`), paging each room's stretch with `LogEntry.slice` and embedding reply
    targets; `ServerSession.reading(_:withImages:)` is a session over it with fresh
    `MediaSettings`, and `archiveNote` the line in the composer's place.
  - Search (`LocalSearch.swift`, `ServerSession+Search.swift`), as apron-web's `search.ts` and
    SearchDialog (#137, #166): `LocalSearch` is the web's logic with its tests mirrored
    (`folded`, `parse` with `user:` and `room:`, `matcher`, `newestMatches` at 100, `snippet`,
    `filterAtCaret`, `withFilterValue`, `searchPeople`), every offset a UTF-16 unit as the web's
    and as `UITextField` counts, and spaces JavaScript's `\s`. `ServerSession.search` scans
    `kept` (what is kept and loaded) off the main actor; `hit` is a result's row,
    `searchNote` and `searchKept` the words beside it, `searchStart` the open room's filter, and
    `rooms(named:)` the rooms list's search by title or id.
  - `Reminders` (`Reminders.swift`): Remind Me, on this device only. One `Reminder` per
    `ReminderKey` (server id, room, message), kept in `reminders.json` beside `servers.json`
    (`FileReminderStore`) and owned by `SessionStore`, which drops a server's reminders with it.
    `ReminderChoice` is the menu's times (Tomorrow is 09:00 the next day, local), and
    `Reminder.label` the row's "Due in 1 hr" or "Due now". `ReminderNotifier` delivers them:
    the app's `LocalReminderNotifier` schedules a UserNotifications calendar trigger under
    `ReminderKey.identifier`, so removing one cancels it, and asks to notify only on the first
    reminder; a refusal keeps the reminder on its row and the timeline says notifications are
    off, with Settings. `MessageReminders` is Remind Me in one timeline: the reminder on each
    message, setting and removing one, Custom…'s first time, and that notice. A tapped notification's `userInfo` reads back as its key, and
    `RootView` opens it as a link to the message (reveal and highlight). Local notifications
    need no Info.plist key.
  - `Profile` (`Profile.swift`): your own profile and status, as apron-web's Preferences >
    Profile. `updateProfile` sends `me` (§3.3.2) and `adopt`s the complete `you` it returns
    (kept object replaced, account name saved, a changed `user_id` followed as a rename).
    `chosenStatus` is your chosen status, read only from a `you` (§4.5.2: others' objects about
    you carry the shown one); `presence(of:)` reads it for you. `Bio` cleans a bio as apron-web's
    `cleanBio` (250 code points); `keepsBio` is `ext:bio` or `ext`. `ProfileForm` is the You
    sheet's name and bio; `save` sends a changed bio, then a changed name, and says what the
    server kept. `StatusChoice.offered` is the picker (optional statuses only where
    `server.status` lists them and not after the server answered otherwise for one),
    `chooseStatus` sends `me {status}` and returns a `StatusAnswer` when the server kept another.
    `Presence` has `unknown` for a value the client does not know (a dashed ring).
  - Mutes (`Mutes.swift`, `ServerSession+Mutes.swift`, §4.5 `status {mute}`), as apron-web's
    `pause.ts` and `setMute`/`handleStatus`: `MuteEnd` (`.at(Date)` or `.untilChanged`) reads a
    wire `mute` (`true`, seconds, `false`/`0` none), sends whole seconds left (at least 1) or
    `true`, and words its end ("until 14:30", "until tomorrow 9:00", "until Fri 9:00", "until
    you resume"). `MuteChoice.pause` is the Pause menu (1 h, 8 h, until the next 9:00, until
    resumed) and `MuteChoice.room` the Mute menu (1, 2, 8 h, until unmuted). `setPause` and
    `setMute(_:_:)` only ask; `pausedUntil` and `roomMutes` change only from the server's
    `status` notifications (sent to every device, and after each sign-in's result, so each
    `auth` sent clears them first). `pause` and `mute(of:)` read them at `Environment.now`, a
    thread taking its room's as `RoomMute.withRoom`; a timer drops ended ones, since the server's
    `mute: false` comes up to 15 s later. `profileLine` puts "Paused until …" first. `mayMute`
    is capability `status` while signed in, and not as a guest without a token to sign back in
    with (`resumable`, apron-web's `registeredSession`), whom apron-web offers neither Pause nor Mute.
  - Idle (`Attention.swift`, `ServerSession+Idle.swift`, §4.5 `idle`), as apron-web's
    `PagePresence`, `setIdle` and `syncIdle`: `SessionStore.attention` goes idle after 5 minutes
    without input (touches through the app's `InputWatcher`, and `composerChanged` via
    `onInput`; input within a second does not restart the wait) or in the background, and hands
    each change to every session. `setIdle` sends `status {idle: <seconds since input>}` or
    `{idle: false}` while signed in with `status`, one at a time per connection (`IdleReport`),
    after a `retry_after` wait or a 5 s backoff doubling to 5 minutes; a connection starts
    attended, so an attended app sends nothing. `suspend()` reports idle, waits up to 3 s, and
    stops: what the app does going to the background.
  - Waits (`RateLimits.swift`, `ServerSession+Limits.swift`, §1.1 `retry_after`, `ext:limits`), as
    apron-web's `noteLimit`, `heldBack`, `limitScope` and RateLimitNotice: `request` notes what a
    refusal holds back (`LimitScope`: a refused `message`, history, and with `ext:limits` a
    `write` on any write or an `upload` on a request adding a new upload) in `limits`, the
    longer wait winning, by account, and refuses held requests before sending with a
    `retry_after` error in the server's words ("Sending is paused" for a message wait).
    `sendWait` and `composerWait(withFiles:)` are what the composer counts down; `WaitWords`
    words it (`17s`, `m:ss`, `3h 12m`, spoken forms, `45s`/`3m`/`2h`), and `RPCError.userFacing`
    adds "Try again in 45s." to every `retry_after` error the app shows. The outbox's sleeps
    read the same clock, so tests tie `Environment.now` to `FakeClock`'s released sleeps.
  - Themes (`ThemeCSS.swift`, `CSSValues.swift`, `ResolvedTheme.swift`, `Themes.swift`,
    `ThemeValues.swift`, generated `WebTokens.swift`), as apron-web's `appearance.svelte.ts` and
    `theme-colors.ts`: `ThemeCSS.parse` is `parseThemeCss` (same grammar, 4000-character and
    100-token limits, unsafe-value rule and messages, lengths in UTF-16 units) with
    `deriveTokens`, `readBase` and `forMode`. `PremadeTheme.all` is apron-web's `THEMES`, read
    by the same parser. `CSSValue` reads what a theme sets without a CSS engine: `var()` with
    fallbacks (a cycle reads as nothing), `#hex`, `rgb()`, `hsl()`, `oklch()`, `oklab()`,
    `light-dark()`, `color-mix(in srgb, …)`, the named colors, `px`, `ms`/`s`, percentages,
    numbers, `cubic-bezier()` and `0 Ypx Bpx <color>` shadows. `ResolvedTheme` is every token
    Ladle applies (`WebTokens.applied`) in both modes; a value it can't read keeps tokens.css's
    and joins `notShown` with the web-only and unknown names. `ThemeFonts` is its three faces,
    each a `FontFamily` list. `Appearance.swift`, as apron-web's `AppearanceSettings`:
    `AppearancePreferences` (mode, theme id or `custom`, the custom CSS; `init(saved:)` is
    `decodeAppearance`, `choosing` is `chooseTheme`), `AppearanceSettings` (owned by
    `SessionStore`, kept in `appearance.json` beside `servers.json`; `shown` is the saved theme
    or a `preview`), `ThemeEditor` (the custom CSS as edited while Preferences is open: live
    preview, Apply, Discard, `close`), and `ThemeBases`, which writes the four `--base-*`
    declarations into the CSS for the color pickers.
  - `ServerPane` (`ServerPane.swift`): `ServerSession.pane`, the server pane's facts as
    apron-web's ServerPane: name, host, description, the connection in words with a tone,
    "Signed in as Ada (guest)", the address, and "Apron 9".
  - `UserProfile` (`UserProfile.swift`): what a profile card shows, as apron-web's ProfileCard:
    `ServerSession.profile(of:in:)` gives the plain name (`UserDirectory.plainName`) and
    `sharesName`, the status in words, `LastSeen` (only while offline, never yours), roles, bio,
    membership of the open room, and whether Message (`mayStartPrivate`), Mention and Add to room
    (`addMember`, `room_join` with `user_id`: `add_members`, or a private room you are in) are offered. A mention chip
    carries `ApronLink.relative(user:)` (`apron:?user=<id>`), which the timeline opens as the
    card; `DraftField.mention` appends `@name ` for the card's Mention.
  - Private rooms (`PrivateRooms.swift`, `PeoplePicker.swift`, `AddedRooms.swift`), as apron-web's
    `private-rooms.ts` (#123, #124, #128, #129, #165), by `private: true` and `parent_room_id`, never
    a `room_id`: `isPrivateRoom` (joined, private, top level) is what `privateRoomTree` lists under
    Private and `publicRoomTree` leaves out; `title(of:)` names an untitled one (`isNamedForMembers`)
    by `PeopleTitle` ("Bram, Chiara", "You", "Private room" while members are unknown) and
    `headerLine` gives its `.privateRoom` line; `directRoom(with:)` is the untitled room of just
    the two of you, from a complete listing (none with a `member_count`). `startPrivateRoom(with:title:)` sends `room_set {private: true}` through
    `createRoom(_:)`, waits for the record (`record(of:)`, 10 s), refuses one that came back
    public (`PrivateRoomError.notPrivate`, nobody added), then `addMembers` one by one, collecting
    `Refusal`s; `message(_:)` reuses the direct room or starts one. `createRoom(title:…isPrivate:)`
    checks a private room, and a thread of a private room, the same way (`threadNotPrivate`), and
    `includeMembers(of:in:)` adds a private room's other members to its new thread.
    `ServerInfo.privateRoomLimit` is `ext.settings.private_rooms`; `privateRoomQuota`,
    `privateRoomsQuietestFirst` and `lastActiveDetail` serve the limit's Leave list.
    `reachesStart`/`privateIntro` are the intro card (history complete, floor at or before
    `ReplayStore.firstRecordLogID`). `ArrivalWatch` (rooms joined without this device asking:
    not created or joined here, nothing created in flight; the first listing per account is the
    baseline) feeds `AddedRooms` (`added-rooms.json`, owned by `SessionStore`, passed to every
    session, dropped with the server): `wasAdded(to:)` and `dismissAdded`. `PeoplePicker` is the
    picker's query and chips; `pickable`/`matching` everyone known but you and `~` ids, by name,
    50 at a time; `privatePeople` marks who you already talk to.
  - Members (`Members.swift`), as apron-web's MemberList (#129, #152, #161): `mayChangeMembers`,
    `mayAddMembers` (`add_members`, or a private room; `Permissions.core` without
    `ext:permissions`), `memberMenu` (Direct Message, Remove; none on your own row),
    `removeMember` (`room_leave` with `user_id`), `removeQuestion`, and
    `memberChangesUnsupported`, set when the server answers either change `unsupported`, which
    stops the offers (`memberChangesRemark`). `addablePeople` is Add people's picker: those known
    who aren't members, else the `@user_id` typed whole (`PeoplePicker.userID(typed:)`).
- `Ladle/`: the app, views only; logic belongs in ApronKit where `swift test` reaches it. The
  design follows apron-web, the official web client (see "Design").
  `App/` (`RootView`: one pane at a time in compact width, a split view with the server rail,
  rooms, room and member column in regular width; `@SceneStorage` restoration; Apron links,
  which open a saved server's room and pass the link's message or member to the timeline as
  its `place`: the message is revealed, scrolled to and highlighted on `hover` for two
  seconds, or a notice says the room lacks it; a `user` opens their profile card. Room lists
  and timelines resolve relative links in their server's content against that server
  (`resolvingLinks(from:)`); one reaching the root has no sender and opens nothing. The
  message menu's Copy Link, and Copy Link and Share on a link in a message or notice, write the web form
  (`ApronLink.outbound`), except a sign-in link, which stays as written so it keeps its token, and
  opens the saved server's sign-in sheet with the token filled in; a notice's long-press menu
  offers Copy Text, Select Text, each code span on its own (`MessageText.code`) and its links;
  a `~private` notice's sign-in link also gets Show QR Code under the text and in the menu, which
  opens `SignInQRSheet` (the warning, then the code, as apron-web's SignInQrDialog);
  Select Text, on a message's menu too, opens `SelectTextSheet`: the text as read
  (`MessageText.plain`) in a read-only `UITextView`, where any part selects with the system's
  Copy, Look Up, Translate and Share, since an iOS `Text` selects only all of itself and its
  long press would compete with the row's menu;
  a server added through the Connect sheet opens once its sign-in succeeds),
  `Profile/` (`YouView`: your avatar, name, bio, status and sign-out on one server, in Preferences > Profile or, `standalone`, from the server pane's Edit Profile; from the
  profile bar; `signOutDialog`; `ProfileCardView`: someone's card, from a sender's avatar or
  name, a mention chip, a member row or a link's `user`; `ServerPaneView`: the server pane, from
  the room list's title or, on iPad, its server head, with Edit Profile, Connect to Another
  Server… and Disconnect, which signs out of that server),
  `Rooms/RoomFormSheet.swift` (the web's RoomForm: title and Markdown description for New Room,
  with its Private toggle, New Thread, Start Thread and Edit Room or Thread), `Rooms/NewPrivateSheet.swift`
  (the + beside Private: the web's PrivateRoomForm, with `QuotaLine` and the limit's Leave list),
  `Rooms/PeoplePickerView.swift` (`PeoplePickerSections`: chips, field and people as form sections),
  `Timeline/PrivateRoomViews.swift` (`PrivateIntroCard`, `AddedBanner`), `Timeline/AddMembersSheet.swift` (the member
  list's Add People; the list's long-press menu and Remove's confirmation are in `MemberList`), `Faces` in `Design/People.swift`, `PinnedDescription` in `Timeline/TimelineView.swift`, `FoldHeading` and the `fixedNow` environment value (the renderer
  pins the rooms list's clock to `PreviewFixtures.now`) in `Rooms/RoomListView.swift`,
    `Rooms/MuteMenu.swift` (`MuteActions`: Mute Room or Thread's submenu, or Unmute, in a row's
  context menu and the room's ⋯ menu; `MutedBell`), a muted row's bell-off and quiet count, the
  header's bell-off button, the profile bar's paused line, and Preferences > Notifications' Pause
  (`Profile/PauseSection.swift`);
  `Servers/` (the server list and iPad rail, `PreferencesView`: apron-web's Preferences (#184), its five sections (`PreferencesSection`) in a navigation stack, opened from the list's toolbar, the rail's foot and the profile bar (Profile, for that server) through `openPreferences`, which `RootView` presents, at a section when asked: Profile (`YouView`, not `standalone`), Notifications (Remind Me's permission and each server's `PauseSection`), Appearance, Media (the media policy and trusted sites), History (`HistoryPreferences`: Retention, how much is kept, why keeping stopped, Export Chats with Include Private Rooms through `ShareSheet`, and Open an Export…); `Archive/ArchiveViewer.swift` (`OpenedExport`, `ArchiveViewer`: an export read-only, after "Load its images?", from History or a `.jsonl` handed to the app, which `RootView`'s `onOpenURL` opens); `AppearanceView`: the mode, the themes with swatches, `ThemeCSSView` (the custom CSS) and `BaseColorsView` (the color pickers); `ConnectView`: add a server and sign in in one
  sheet, `QRScannerView`: the VisionKit sign-in scanner), `Rooms/` (`RoomSearchField`: Search Rooms in the iPad sidebar, whose navigation bar is hidden), `Timeline/` (messages, select mode's check circles and `SelectionBar` (Copy, Move, New Thread) in the composer's place, `SearchView`: Search Local History, from the magnifying glass beside a room's title, ⌘F, or Search Rooms' Search Messages, `RateLimitNotice` and Send's countdown over the composer while a wait holds it back, composer with the
  mention list, the `:` emoji list (`EmojiSuggestions`), the `#` room list and the command list (`CommandSuggestions`: usage and
  summary, scrolling past five rows; picking fills `/name ` and keeps the keyboard up), reaction picker (custom emoji by category first),
  member list, `CustomEmojiViews`: `EmojiText` draws each marked key as its image at the line's
  height inside one `Text`, read by VoiceOver as its `alt`, `ReactionGlyph` an emoji, a custom
  emoji's image or a dashed placeholder for a key the catalog lacks, `EmojiImages` the images,
  `static_url` under Reduce Motion (Ladle draws the first frame of an animated image either
  way); message text, room and thread descriptions, the welcome and the server description
  draw custom emoji, and each fetches the catalog when its text could hold a key; `EmbedViews`:
  `og` embeds as the web's EmbedCard (a hosted image, site, title, two lines; with `og.video` or `og.audio` that `OpenGraph.player(gate:)` allows, the card plays it inline and only its text opens the `url`; media the gate holds back shows `OpenGraph.ask(gate:)` as a `MediaAskTile` under the card, a video's even when the image loads), others as a
  labeled fallback card; `FetchedLinkCard`: a fetched preview as the same card, fetched with
  LinkPresentation's `LPMetadataProvider` when the row appears, while Show Link Previews (Ladle's
  page in the Settings app, `Settings.bundle`, on by default) is on; it replaces a bare `link` embed's
  fallback card, and plays the page's `remoteVideoURL` (`LinkPreview.playableVideo`) inline; upload embeds as a picture, an inline video, an audio player, a file card that opens in
  Quick Look, or a pending card with progress; `Attachments`: the draft's tiles, picked files
  in the temporary directory (cleared at launch) until `AttachmentStaging.prepare` fits them into
  `Drafts.staging`, the camera; `TimelineView` binds the composer to the room's kept draft, or to
  an open edit beside it, and fits dropped and picked files into that room's draft by key, so one
  finishing after the room is left still lands; `TypingIndicator`: who is typing above the
  composer in regular width, with `TypingDots`, still and dimmed under Reduce Motion; `PaneLoadingViews`: `LoadingPill` (the web's TimelineLoading pill, over the foot of the timeline or at its top) and `CatchingUpLine` (the glint along the navigation bar's foot); in compact
  width a centered denim line under the navigation bar says it, standing for the web's header
  subtitle so the centered title never moves; `VoiceRecorder`: voice notes as
  `audio/mp4`; `ReminderViews`: `ReminderBadge`, the due line and Clear on a reminded row,
  which takes an accent edge, and `ReminderDateSheet`, Custom…), `Media/` (`MediaLoader`: images decoded at their shown size and files for Quick
  Look, no cookies; `MediaAskTile`: media the gate holds back, its kind and full URL (two lines, cut in the middle, as apron-web #186), Load on a tap, Always Load from its host in its menu; `MediaViewer`: the room's images full screen, as the web's viewer), `Design/`
  (`Tokens.swift`, generated; `Apron`: colors by job, text roles, motion; `People`: avatars,
  StatusDot and RoleBadges; `Components`: the web's UnreadCount, Callout, ActionBanner, EmptyState, buttons).
  `Servers/KeychainStore.swift` is the only place a secret is persisted (generic password,
  service `app.ladle.ios.token`, account = server id).
- `LadleTests/`: hermetic app tests (no network, no server).
- `LadleShots/`: the design-review renderer (see "Design review").
- `Packages/ApronKit/Tests/ApronKitIntegrationTests/`: `ServerSession` against the real Rust
  server. `Aprond` copies the binary to a temporary directory (its build tree may be rebuilding),
  starts it per test with `--store memory --email.enable --email.sender log` on a free loopback
  port, and reads email codes from stderr (`publicURL:` sets `--public-url` instead, which the
  log sender refuses, for the links the server writes with it). The server's defaults are read-only guests and
  passkeys only for configured origins, so `Aprond` adds `--guest.posting`, `--webauthn.origin`
  for its port, `--limit.guest-posts-per-minute 0` (guests on one address share five writes a
  minute), and an `--admin-token-file` (`adminToken` signs in the admin, which `/avatar`
  needs). A thread goes when its last member leaves. The binary defaults to the sibling
  `apron-server-rust/target/release/aprond`; `APROND` overrides it.
- `Config/Domains.example.xcconfig`: template for the gitignored `Config/Domains.xcconfig`.
  `Config/Ladle.entitlements` is generated (`scripts/associated-domains.sh`, "Identity and
  sign-in").
- `scripts/sync-fixtures.sh`: copies the protocol's replay fixtures at the `scripts/SPEC` commit
  into the package's test resources; `--check` fails on drift. To follow a newer spec, review
  its changes, move the pin, rerun the script.

## Build and test

- `Ladle.xcodeproj` is generated by XcodeGen and gitignored. Edit `project.yml`, never the pbxproj.
- `./build.sh build` builds the `Ladle` scheme with DerivedData in `build/`. With no simulator
  it uses the generic iOS Simulator destination.
- `./build.sh test` runs the fixture drift check, the design checks (`tools/design/tokens.py`,
  `theme-goldens.py`, which needs `bun`, `fonts.py`, which needs `uv` and fetches fontTools
  on its first run, and `emoji.py`; all read the apron-web clone) and then the `Ladle` scheme's tests on the
  "Ladle iPhone" simulator (create it once with `xcrun simctl create "Ladle iPhone" <iPhone
  device type> <iOS runtime>`). Set `DEST` to override.
- The gate is `scripts/sync-fixtures.sh --check && swift test --package-path
  Packages/ApronKit`. It checks the fixture copies against the spec clone, then runs the fixture
  gate below, the unit tests, and the integration tests. It needs no simulator. The integration
  tests skip when `aprond` is missing; set `APRON_REQUIRE_SERVER=1` to make that a failure.
- aprond has no page-size flag; the paging test passes `limit` through the session's page size.
- `tools/testflight.sh` archives a Release build and uploads it to App Store Connect for
  TestFlight, with cloud signing through a Team API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, the key
  in `~/.appstoreconnect/private_keys/`). The build number is the commit count, so it needs a
  clean tree. `tools/beta.sh` runs it, then waits for processing, adds the build to the Public
  TestFlight group, sets its What to Test notes (a file argument, else the commit subjects since the last uploaded build) and submits it for beta review, through `tools/asc.py` (needs `uv`).
  `docs/PRIVACY.md` is the privacy policy TestFlight links to, and
  `Ladle/PrivacyInfo.xcprivacy` declares no tracking and no collected data; keep both true.
- Deployment target is iOS 27.1 because the newest installed SDK is iOS 27.1 (Xcode 27.1); a
  target cannot be newer than its SDK. Bump to 27.2 in `project.yml` once Xcode ships that SDK.
  `Package.swift` says iOS 27.0: a floor for the `LadleShots` renderer, not the app's target.

## Design

Ladle follows apron-web (the clone at `~/Developer/forks/apron-web`, its `origin/main`),
translated through the HIG. Its narrow layout (under 720 px) is the iPhone reference; its wide
layout (960 px and wider) is the iPad split view.

- Tokens are generated, never copied: `tools/design/tokens.py` reads `tokens.css`, `rail.css`
  and `appearance.svelte.ts` at the apron-web commit in `tools/design/UPSTREAM` (from the clone
  above, or `APRON_WEB`; it fetches the clone's origin when the pin is missing) and writes
  `Packages/ApronKit/Sources/ApronKit/WebTokens.swift` (every declaration as written, both modes,
  aliases kept as `var()`; the premade themes' CSS; the theme limits) and
  `Ladle/Design/Tokens.swift` (an accessor per token Ladle uses). `--check` (run by
  `./build.sh test`) fails when either differs from a fresh generation and says when apron-web's
  `origin/main` has moved past the pin. `tools/design/theme-goldens.py` runs apron-web's own
  `parseThemeCss` at the pin with bun and writes the goldens `ThemeTests` holds the Swift port to.
  To follow a newer apron-web, review its design changes, move the pin, rerun both.
- Themes, as apron-web's (#174): every token reads the active theme (`ActiveTheme.shared`, a
  `ResolvedTheme`), so `Palette.accent` and `Tokens.Space.s2` stay what views write and a new
  theme redraws every view that reads one, with no per-view code. `ResolvedTheme` reads a
  theme's own value for a token, else tokens.css's, with `var()` read against the theme first,
  so an alias follows it (`--focus` is the theme's `--accent`, `--selected` its `--ink` at 8%).
  Under Apron, colors, grounds by depth, spacing, radii, avatar sizes, durations and easing are
  tokens.css's verbatim in both modes. Accent is what you can do; denim is where you can go;
  every status color carries a word or shape; the private color always comes with its lock
  (`Palette`'s doc). A theme may move any of them; the premade themes move only grounds, lines,
  ink, accent and denim.
- Text uses the web's roles (`TextRole`: caps, xs, sm, ui, field, body, title). Each role's web
  px value is its size at the Large Dynamic Type setting and scales from there with the HIG's
  table, whatever the face. The face is the theme's (`TextFace`, `ThemeFonts`): `--font-sans`
  for the interface and the navigation bar's title, `--font-chat` for message text (the
  `textFace` environment value, set around message bodies, as the web's `.ap-msg-text`), and
  `--font-mono` for code (`apText(_:mono:)`). Each is the first family in the theme's list the
  device has: SF, SF Mono, SF Rounded or New York for the generic and system names, a bundled
  face, or an installed one. Apron and Linocut are SF and SF Mono, as on the web. Italic is the
  face's italic cut, else its `ital` axis, else the browser's 14° synthetic oblique as a shear in
  the font's matrix (`Italic` in ApronKit decides; `BundledFonts` applies it): Recursive, Nunito
  and SF Rounded have no italic. `apText(_:italic:)` sets it; markdown emphasis takes it, and
  bold, from the nearest `apText`'s face (`RoleFace.emphasized`), since SwiftUI's own `.italic()`
  and `.bold()` do nothing for a face without those cuts. A form `Section`'s header and footer
  take `formHeader()` and `formFooter()`, the web's field label and hint in `--font-sans`.
- Anything tappable takes 44 pt (`touchTarget()`, the web's `--touch-target`). Native controls
  where the HIG expects them (navigation stacks, sheets, swipe actions, context menus,
  confirmation dialogs, the segmented control, the emoji keyboard), styled with the tokens.
- Reduce Motion turns the web's motion off (`Motion`); Increase Contrast swaps the theme's `line`
  for its `line-strong` and its `ink-muted` for its `ink`, which the web has no counterpart for.

## Design review

The iOS Simulator does not run here (CoreSimulator 1171.7 is older than Xcode 27.1's 1174.9;
never restart its services or kill its processes). Screens are reviewed on this Mac instead:

```sh
./build.sh shots /path/to/out      # PNGs of every screen, plus contrast.json
```

`LadleShots` is a debug-only Mac Catalyst app target built from `Ladle/` (minus `LadleApp.swift`)
plus `LadleShots/ShotsApp.swift`. It seeds `PreviewFixtures` (and a fetched preview for the busy room's wiki link) and renders, at 390x844 pt
(compact width) in dark and light: the first run (no servers), the server list, Connect, Connect after a scanned sign-in, the room list, the busy room, the
mention list, the member list and the reaction picker, the composer with attachments, a room
of uploads (image, video, file, audio, pending), the media viewer, the composer over the text
limit, a read-only guest's sign-in prompt on the demo server, custom emoji in text, a
description and reactions with a right-to-left line (the kitchen room), the reaction picker
with the custom emoji, the composer's `:` list (`:pa`), `:smi` with the custom `:smilingpan:` first, the standard emoji and the first row highlighted (`ladle-emoji-standard`), its command list (`/inv`, answered by
`PreviewServer`'s `/help`), link cards, a room chip and Apron link chips for a message, a room, a thread, a user and another server (the Icon sketches thread), the `#` room
list, the Select Text sheet, a reminded message, Remind Me's Custom… sheet, every markdown block and highlighted code in python, diff, json and an unknown language left plain (the markdown room, also in Ferrous as `ladle-markdown-ferrous-<mode>`, where inline code takes Rec Mono), media from untrusted sites waiting for Load and then loaded, one of them on a host that never answers (the remote room), the You sheet, and profile cards for Ada (Mention and Add to Room in the private ops room) and Dev (offline, last seen), the server pane for Home and the demo, and a mention of you as a chip (the busy room opened at it), a kept draft (a reply, text and a photo), Ada and Bram typing in the random room (the denim line under the bar), the `@&` role list and a role chip in the design room, the muted design room (its header's bell-off), the Release thread's rename line (and Dev's join line in the busy room), the Start Thread form on Bram's message, #general's threads in the room list (five joined, Inactive folded, Other Threads with "4d", "9w", "2y" and "1 more…"), and Inactive unfolded with its untitled thread open, the busy room's "Reconnecting…" and "Checking for new messages…" pills, its "Loading earlier messages…" pill, its catching-up line under the bar (`ladle-catching-up-line`, and on iPad `ladle-ipad-catching-up`), the room list with your dot as the dashed ring (`ladle-rooms-reconnecting`), each held through the renderer-only `heldPaneLoading` and `heldAwayWords` environment values, the kitchen's pinned description (the emoji shot), put away (its first line under the title), and Edit Room, the Private section with faces (`ladle-rooms-private`), the conversation with Ada (faces, plum header and its line, the intro card), Launch plan's "You were added" banner, New private conversation empty and with two picked (chips, Name), New Room with Private, and at the limit after starting home's fifth private room (`ladle-private-full`, taken after the others), Add People to ops with Ada picked and "@carol" typed, `/invite-device add phone`'s notice in ops with Show QR Code, and its sheet's warning and code (`ladle-signin-qr-*`), Launch plan's members with Add People, a refused `/kick @Dev` in ops (its reason as a notice, the draft given back; `PreviewServer` refuses removing someone else), #general's members with Offline folded (`ladle-members-folded`), the demo lobby's truncated listing ("Showing 3 of 1204") and a profile card for someone it leaves out ("Not among the recently active members"), the room list and Preferences > Notifications while paused (`ladle-notifications-paused`), and sending and uploads paused over the busy room's composer (taken last, as its waits hold home back); the floating day over the busy room scrolled back to Eun-ji's mention (`ladle-floating-day`), that mention mid-pulse (`ladle-mention-pulse`), the demo's welcome before `auth` in its first room, help (`ladle-welcome`); the busy room at AX3; the busy room in Ferrous, Gumball, Linocut and a custom CSS theme (`ladle-timeline-<theme>-<mode>`), the markdown room in Ferrous, Gumball and the custom theme (`ladle-markdown-<theme>-<mode>`: bold and oblique emphasis in Recursive, Nunito and SF Rounded), and drawn in Apron then given Linocut in place (`ladle-timeline-switched-linocut-dark`: a new theme redraws open screens); Preferences' sections and History; Search Local History for "icon" across rooms, and started narrowed to the design room with `room:` suggesting rooms at the caret (`ladle-search-filtered`; the renderer opens it unfocused, as a focused Catalyst field selects all of itself), and Search Rooms for "des" with Search Messages under it (`ladle-rooms-search`); the busy room in select mode with its last three messages picked (`ladle-select`), and what Copy puts on the pasteboard for them, shown as text (`ladle-select-log`); home exported and opened: "Load its images?" (`ladle-archive-ask`), its rooms (`ladle-archive-rooms`) and the busy room read-only with the export's line in the composer's place (`ladle-archive-timeline`); Appearance with Ferrous chosen, and the custom theme's CSS with its "not used on iOS" line; and the iPad
split view at 1180x820 pt (regular width) in dark and light, on the busy room and on the random room with its typing line. Sheets render as root views,
because `drawHierarchy` does not see a sheet's window. It captures in process with
`UIView.drawHierarchy` at 2x (a `URLProtocol` answers the fixtures' hosted files with
generated pictures, and fails the remote room's unreachable host; a video has no frame to draw, so its tile stays black), writes `contrast.json` (for each premade theme, WCAG ratios of the text tokens on their
grounds), and quits. `TZ=UTC` keeps the times reproducible.

The sign-in shots come from a store of their own (`PreviewFixtures.makeSignInStore`: one server,
`owner.example`, that offers passkeys, email, its own page, tokens and guests; the renderer's
`LadlePasskeyDomains` holds it): Connect on Passkey in Sign In and Create Account
(`ladle-connect-passkey`, `-create`), on Passkey for the demo, which this build can't use
(`ladle-connect-passkey-unavailable`), on External waiting for the page's code
(`ladle-connect-external-code`), Profile's Sign-in with the nudge and Add Passkey, Add Email and
Add External Sign-In (`ladle-you-signin`), Add Email waiting for its code (`ladle-you-add-email`),
the room list held for a passkey (`ladle-rooms-held`) and with "Add a sign-in" in the profile bar
(`ladle-rooms-nudge`). The renderer opens Connect and Profile there with `startMethod`,
`startPasskeyMode` and `adding`, which the app never sets. The sign-in link dialog is a
confirmation dialog, which `drawHierarchy` does not see either; its words are in
`SignInLinksTests`.

Limits of the Mac render, each checked on this machine:

- Mac Catalyst ignores Dynamic Type: `UIFontMetrics` returns 17 pt for body at AX XXL. The
  renderer sets the `fixedTypeSize` environment value, which sizes text roles from the HIG's
  iOS Dynamic Type table. The app never sets it. System chrome (navigation bar buttons, list
  chevrons) stays at its default size in the AX3 shot.
- Large navigation titles do not draw on Catalyst, so every screen uses inline titles, which
  also match the web's 48 px header.
- The software keyboard never appears on a Mac, so the reaction picker shows its field without
  the emoji keyboard.
- Gestures (swipe actions) and haptics cannot be shown in a still.
- The renderer sets `scenePhase` to `.inactive`: every room shot reads one store, and a pane in
  the active app marks its room read, which would strip the New line and the badges from the
  shots after the first. The app never sets it.
- A still has no scrolling and the capture comes after the floating day's 1.2 s and the pulse's
  0.9 s, so the renderer sets `shotPins` (`Timeline/TimelinePolish.swift`): the floating day
  held shown, the pulse frozen a third of the way, and a row scrolled to. The app never sets it.
- VisionKit's scanner does not exist on Mac Catalyst, so the camera cover is never shot; the
  renderer passes `canScan: true` to show the Scan QR Code entry, and seeds the scanned state
  through `prefill`, the path a tapped link takes.

Why not the other routes: running the iOS app as "Designed for iPad" on this Mac fails twice.
First, `xcodebuild -destination 'platform=macOS,variant=Designed for iPad,arch=arm64'` says "My
Mac's iOS Support Version 27.0 is less than Ladle.app's iOS 27.1 deployment target". With the
target lowered to 27.0, it says "Provisioning profile "iOS Team Provisioning Profile: *"
doesn't include the currently selected device" (this Mac). Fixing that means registering this
Mac with the developer account (`-allowProvisioningUpdates`), which an agent should not do
unasked. An ad-hoc signed iOS build launched with `open` fails with "incorrect executable
format". The third route, `ImageRenderer` in a macOS test host, was not tried once Catalyst
worked.

## Conformance fixture gate

`ReplayFixtureTests` runs every file in `Packages/ApronKit/Tests/ApronKitTests/Fixtures/wire/
replay/`, every variant twice (literal frames, and with `"jsonrpc":"2.0"` added to each frame),
checking each `expect` step and the final `expected` projection. Currently 18 files, 42 variants,
84 runs; the aggregate test pins those counts, so bump them when fixtures are added upstream.
The fixtures are copies: `scripts/sync-fixtures.sh --check` fails when they drift from the
pinned commit. Run it before `swift test` (the gate line above does), and `./build.sh test` runs it too. The session fixtures (`wire/session/`) are phase 2.

## Rules

- Swift 6, `SWIFT_STRICT_CONCURRENCY: complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION: nonisolated`.
  Shared state is an actor or a value type.
- Secrets live only in the Keychain through `TokenStore`. `ServerRecord` and `servers.json` never
  hold a token.
- `ServerRecord` is plain Codable persisted as JSON. Every field after `id` and `url` gets a
  default in `init(from:)`, so older files keep loading. Adding a non-optional field without a
  default breaks saved files.
- Apple frameworks only: Foundation, URLSession WebSockets, AuthenticationServices,
  Security, SwiftUI, Observation, Network (`NWPathMonitor` reconnects when the network
  returns), VisionKit (the sign-in QR scanner, not on Mac Catalyst), and for attachments PhotosUI, AVFoundation, AVKit, QuickLook, ImageIO,
  UniformTypeIdentifiers and CryptoKit (cache file names), CoreImage (`CIQRCodeGenerator` draws a sign-in link's QR code; not a required-reason API), and UserNotifications (Remind Me's
  local notifications; no usage string, no required-reason API). PhotosPicker and the document
  picker run out of process and need no usage string; the camera and the microphone (voice
  notes) have theirs in `project.yml`; the camera's names scanning too. Nothing in them is a required-reason API: files go only to the server the user sends them to.
  LinkPresentation fetches link previews; it is not a required-reason API either, and a
  preview goes nowhere but the screen and the cache. The Show Link Previews setting is read
  from `UserDefaults`, which is, so `PrivacyInfo.xcprivacy` declares it with reason `CA92.1`. A third-party package needs a justified entry here. None so far.
- Bundled fonts: only the faces apron-web carries for its themes (#174), Recursive's casual
  sans and mono and Nunito, under the SIL Open Font License 1.1. `tools/design/fonts.py` (run
  with `uv`, which brings fontTools) converts apron-web's WOFF2 files at the pin into
  `Ladle/Fonts` (TrueType, one renamed font per file, the licences beside them); `--check` runs
  in `./build.sh test`. `BundledFonts` registers them for the process with CoreText the first
  time a theme names one, so neither target needs `UIAppFonts`, and puts each Latin Extended
  cut behind its Latin one as a cascade, as fonts.css's `unicode-range` does. Weight is the
  `wght` axis. Registering fonts is not a required-reason API. No other font is bundled; a
  theme that names another gets it only if the device has it installed, as on the web.
- Replay rule: a record replaces only on a numerically greater `log_id`, or a tombstone at an
  equal one; a room record without `log_id` always replaces; replacement is whole. Compare
  `log_id`s with `LogID`, never as strings.

## Identity and sign-in

The primary v1 sign-in is a bearer token (`scheme: "token"`, §3.2.1), pasted into the app or
scanned from a QR code, obtained from another client. This works today with no server changes:
the web client has a "sign in with a token the server gave you" mode, the public demo issues
tokens through `/invite-bot` (a bot identity), and the protocol allows a command that issues
more tokens. The Rust server's `/invite-device add [<id>]` (after apron-server-cloudflare's) mints a
device token for the signed-in account that signs in from any origin, or with none; its `auth`
result carries no `token`, so the device keeps the one it presented. Its notice includes a §A.4
sign-in link (`https://link.apron.chat/#server=…&token=…`), which apron-web and Ladle show as a QR code.
The server writes the link only with `--public-url`.
Adding a server, a scan of that link fills in the server and the token, and you tap Connect; a
link never signs in by itself (link.apron.chat SPEC §6). `ConnectView.canScan` hides the scan
entry where `DataScannerViewController` is unavailable; only the renderer sets it.

Other tokens are bound to the origin of the client that obtained them (§3.2.1, §4.10). So each
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

Also email with a typed code (§4.11), passkeys and the server's own sign-in page:

- External sign-in (§4.11.5) opens the server's page in `ASWebAuthenticationSession`, through
  SwiftUI's `webAuthenticationSession` (`Servers/ExternalSignIn.swift`). The proposal's
  `return_url` is the record's origin (`SignInPage.returnURL`), and only where that host is one of
  the build's associated domains, since the session's `.https(host:path:)` callback requires "a
  member of a domain associated with the app" (the symbol's documentation, iOS 17.4); it does not
  say which service, and only `webcredentials` entries are added. link.apron.chat cannot be the
  return: its association file lists another team's app under `applinks` only (fetched
  2026-10-31). Elsewhere the proposal has no `return_url`, the page shows a code, the session
  stays open (a callback scheme that never fires) until the user closes it, and the code goes in
  the form on the proposing connection. A page `url` other than `https`, or `http` on a loopback
  host, is refused before anything opens. Apple's documentation for the session
  (https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
  says nothing about passkeys or WebAuthn inside it; an Apple engineer's forum reply
  (https://developer.apple.com/forums/thread/738229) points third-party sign-in at the session,
  which is suggestive, not documentation. No reference server offers `external` (aprond answers
  `unsupported`), so the flow is unit-tested against a scripted server only.
- Proposals (`Proposals.swift`, as apron-web's `proposals.ts`): every email and external proposal,
  sign-in or addition, is remembered by its `state` in `proposals.json` beside `servers.json`,
  8 at most, for an hour, before it is sent. A sign-in link with that `state` continues it on the
  proposal's server whatever `server` it names (`LinkRoute.proposal`); any other sign-in link for
  a saved server opens `SignInLinkPrompt`'s dialog (`App/SignInLinkDialog.swift`: Sign In, and
  Add It where an account is signed in there), and presents its token as `token`.
- Additions (§4.11.1, §4.11.3, `ServerSession+SignInWays.swift`): Add Email and Add External
  Sign-In propose on the signed-in connection, which alone takes the code; Add Passkey registers
  on it. `ServerRecord.Account.added` keeps what was added on this device, and `wayBack` is
  apron-web's nudge (§3.2.1's SHOULD): the profile bar's "Add a sign-in" and the Sign-in section's
  line.
- Native passkeys with `ASAuthorizationPlatformPublicKeyCredentialProvider` for the owner's own
  domains (`Passkeys.swift`, `ServerSession.usePasskey`, `Servers/PlatformPasskeys.swift`). Both
  steps go on one connection; `register` on a signed-out connection joins as a guest first, since
  aprond refuses it otherwise ("Sign in as a guest before adding a passkey") and makes a guest's
  registration a new account under a new `user_id`. Before the system sheet opens:
  apron-web's RP ID check (#183, `PasskeyChallenge`: the RP ID is `rp.id` when registering and
  `rpId` when signing in, else the server's host; it must be the host or a domain the host is
  under), then the build's associated domains (`PasskeyDomains`, from the Info.plist key
  `LadlePasskeyDomains`, since entitlements can't be read at run time), then the record's origin
  must be `https://<rpID>`: aprond binds the ceremony and its token to the connection's `Origin`
  (`with_registration_origin(c.origin)`), and the platform signs `https://<rpID>`. A held session
  (`heldAccount`, `passkeyHold`): a passkey account whose saved token the server refused signs
  back in with one tap on the room list's banner. Constraints, from Apple's docs unless marked:
  - The app needs a `webcredentials:<domain>` associated domain, and the server must serve
    `https://<domain>/.well-known/apple-app-site-association` over https with a valid certificate
    and no redirects, listing `MP92RCAPRG.app.ladle.ios` under `webcredentials.apps`
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
    `Config/Domains.xcconfig` (`APRON_ASSOCIATED_DOMAINS`, space- or comma-separated), with
    `Domains.example.xcconfig` committed. `Config/Ladle.entitlements` is generated and
    gitignored: xcodegen writes `applinks:link.apron.chat`, then `scripts/associated-domains.sh`
    (run by `build.sh` and `tools/testflight.sh` after `xcodegen generate`) adds
    `webcredentials:<domain>` for each entry. An empty list adds nothing, rather than a bare
    `webcredentials:`, and an entry that is not a domain stops the build, since the app's
    `LadlePasskeyDomains` would still list it. `ServerRecord.rpID` stays optional and unused.
  - A server whose domain is not among them (`server.apron.chat`, whose RP ID is `apron.chat`)
    can't use passkeys here: the Passkey method says so and offers the web client in Safari,
    where the user signs in and gets a token for this device (`/invite-device add`). The demo
    offers `webauthn` only to its web client's origin, and no `external` or `email` (its `server`
    frame from origin `https://server.apron.chat` lists `token` and `guest`, fetched 2026-10-31).
  - Verified here: the ceremony's server side and Ladle's WebAuthn JSON, against aprond
    (`PasskeyIntegrationTests`, with `SoftwareAuthenticator`, a CryptoKit P-256 authenticator
    that writes `none` attestation and `clientDataJSON` with origin `https://<rpID>`, as iOS
    does): a guest creates an account, another connection signs in with the passkey and its
    token resumes, a passkey is added to an email account and signs in to it, and a mismatched
    origin is refused before any sheet. The owner's server serves the association file with
    `webcredentials.apps` `["MP92RCAPRG.app.ladle.ios"]`, and its deploy passes
    `--webauthn.rp-id` and `--webauthn.origin https://<host>` for its own host, which is what
    the platform signs (checked 2026-10-31). `scripts/associated-domains.sh` writes the
    entitlements and the Info.plist key expands.
  - Needs a device: that the sheet appears and the platform's `clientDataJSON` origin is
    `https://<rpID>` (the forum reply above); that the association is picked up from the
    owner's server (Apple's CDN caches the file); `ASWebAuthenticationSession`'s `.https`
    callback with a `webcredentials` domain; and the cross-device (QR) passkey path.
- Native push needs a §4.9.2 `relay` with APNs, which is out of scope for v1.

## Parity with apron-web

Ladle has every feature apron-web has, in an iOS form, and may add more; it never leaves one
out. `docs/PARITY.md` lists each apron-web feature with Ladle's status (has, partial, missing,
N/A-iOS) and the gaps in order. Update the row in the same commit as the work, and add rows when
an apron-web merge brings a new feature.

## Cleanup

- `build/` is DerivedData, including the `LadleShots` build; delete it when a work session ends. `Packages/ApronKit/.build/` is
  SwiftPM's; both are gitignored.
- Delete simulators you create once a phase is done, except "Ladle iPhone", which later phases
  reuse.
- Never commit `Config/Domains.xcconfig`, a token, or the owner's personal identifiers. The team
  ID and bundle ID are fine.
- Commit with `git commit -F <file>` and keep main current on origin. Never force-push.
