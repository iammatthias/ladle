# Ladle and apron-web feature parity

This is the backlog of record for parity with apron-web. The rule is that every apron-web feature exists in Ladle. The iOS form may differ. Ladle may do more. Nothing is left out.

The apron-web side is the fork at `forks/apron-web`, branch `homelab-3`. It carries upstream through #178 and #179, and role mentions (#181), plus three fork features: hidden deleted messages, `og:video` cards, and the sign-in QR code. The Ladle side is `main` at the time of writing. The media gate and block markdown landed in 6273e57 and deac4e3.

Each "has" was checked against Ladle's code, not its docs. `docs/UX.md` sections 3.10 to 3.12 describe the profile card, You and the server pane as built.

## How to read the tables

- **Status** is one of: `has`, `partial`, `missing`, `in progress`, or `N/A-iOS`.
- `N/A-iOS` is only for features with no iOS counterpart, such as a browser install prompt. Each such row gives the reason.
- **apron-web** cites a PR number from the git log where one exists. Otherwise it cites `behavior.md` (shortened to `bh`) or a source file.
- **Ladle** cites files under `Ladle/` or `Packages/ApronKit/Sources/ApronKit/` (shortened to `Kit/`).
- A note says what is missing for `partial` and `missing` rows.

## 1. Connection, reconnect, and status

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Default server, the public demo | bh, `.env.production` | has | `Servers/ServerListView.swift` (Official server row) | |
| Connection-status probe after a failed upgrade (`?apron_connection_status=1`, `Retry-After`) | #111, bh | has | `Kit/ConnectionStatus.swift` | |
| Backoff from 1 s to 1 min with jitter; fast first retry | #127, bh | has | `Kit/ServerSession.swift` (`backoff`) | |
| Liveness check when the app returns or the network comes back | #127, bh | partial | `App/RootView.swift` (scene phase, `NWPathMonitor`) | Ladle stops and restarts the session. It closes a socket silent for two ping intervals. It does not ping at once on return. |
| `retry_after` on the whole connection; `denied` stops reconnecting with "Signed out" | bh | has | `Kit/ConnectionState.swift`, `Rooms/RoomListView.swift` banner | |
| Quiet reconnect: the page stays as it was, Send waits | #127 | has | `Kit/ServerSession.swift` outbox, `Timeline/TimelineView.swift` | |
| "Reconnecting…" and "Checking for new messages…" pill with 400/600/300 ms timing | #72, #127, #173 | partial | `Kit/ConnectionState.swift` | Ladle shows state in a banner and a label. There is no floating pill with the anti-flicker timing, and no "Checking for new messages…". |
| Other rooms catching up as a thin line under the header | #173 | missing | | |
| "Loading earlier messages…" pill at the top | #173 | partial | `Timeline/TimelineView.swift:49` (`ProgressView` row) | A spinner row shows and takes space. No text, and it is not a floating pill. |
| Catch up the open room first after a reload or reconnect | #169 | has | `Kit/ServerSession.swift` (reconnect catch-up) | |
| Your own dot shows the connection state (dashed ring) | bh | missing | `Rooms/RoomListView.swift` profile bar | The profile bar shows presence only. |
| Request toast after 600 ms ("Leaving…"), error toast with × | #69, bh | partial | `Timeline/TimelineView.swift` banner | Errors show inline with Dismiss. No in-flight toast. |
| Connection error in a corner with × that stays away until it clears | bh | partial | `Rooms/RoomListView.swift` banner | Banner has no "stay dismissed until it clears" rule. |
| First room shown waits up to 3 s for its thread listing | bh | missing | | Thread cards can shift the timeline after they arrive. |
| New version deployed: Reload or Later | #7 | N/A-iOS | | The App Store and TestFlight update the app. |

## 2. Reload, kept view, and local history

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Restore the last view on relaunch | #56 | partial | `App/RootView.swift` (`@SceneStorage` server and room) | Server and room come back. Messages wait for the socket. |
| Kept view: rooms, last day of messages (150 per room), members, shown at once | #56, #102 | missing | | No on-disk cache. UX.md 2.5 plans one. |
| Placeholder rooms and messages on a first visit, "Connecting…" then "Loading messages…" | bh | missing | | |
| History kept on device with Retention (a day, a week, 30 days, a year, forever, none) | #137 | missing | | |
| Catch up from the kept checkpoint (`latest_log_id`, §4.3.5) | #137 | partial | `Kit/ServerSession.swift` checkpoints | In memory only. Lost on relaunch. |
| Older pages from the device first, then the server | #137 | missing | | |
| Preferences says how much is kept, and why it stopped | #137 | missing | | |
| History deleted on sign-out, kept apart per account and server | #137 | missing | | Nothing kept yet. |
| Drafts kept per room and thread | bh, `pane-drafts.svelte.ts` | has | `Kit/Drafts.swift`, `Timeline/TimelineView.swift` | Text, mentions, reply target and ready files, by server and `room_id`, in `drafts.json`. Ladle keeps them across a relaunch, where the web keeps them for the page only. An edit is not kept, as on the web. |
| Warn before reload that unsent text is lost | #7 | N/A-iOS | | No reload. Drafts persist instead (row above). |
| Room address in the URL fragment; paste a link into an open tab | #86, #114 | N/A-iOS | | iOS uses `@SceneStorage` and `onOpenURL`. Deep links are in section 15. |
| Back and Forward between rooms visited | #85, "Back and Forward move between rooms and threads" | N/A-iOS | | The navigation stack and the back swipe cover this. |

## 3. Sign-in and accounts

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Connect screen: server URL, server's avatar, title, address, description, welcome | #138, bh | has | `Servers/ConnectView.swift` | |
| Recent servers listed by normalized address | bh | has | `Servers/ServerListView.swift` | Ladle keeps every saved server, a superset. |
| Guest sign-in | bh | has | `Kit/SignIn.swift` | |
| Token sign-in, with optional invite name | bh | has | `Kit/SignIn.swift` (`.token`, `.signUp`) | |
| Email sign-in on a connection of its own, 15-minute code window | bh | partial | `Kit/SignIn.swift` (`.emailProposal`, `.emailCode`) | Code goes on the proposing connection. Not verified in code: the separate unsigned connection and the 15-minute close. |
| Email link sign-in (`#token=…&state=…`) | bh | partial | `Kit/LinkRoute.swift`, `Kit/ApronLink.swift` | Token links open the sign-in sheet. The `state` matching and the "Sign in or Add it" dialog are not built. |
| Passkey sign-in and Create account | #27, #41, #46, #140 | missing | | UX.md and AGENTS.md list the open questions (associated domains). |
| External sign-in (`scheme: external`, return URL or code) | bh | missing | | `ASWebAuthenticationSession` is the iOS form. |
| `signup` vs `auth` schemes labeled in the form | bh | has | `Kit/ConnectForm.swift` | |
| Sign-in link dialog: "Sign in to *server* with this link?" with a warning | bh | partial | `Servers/ConnectView.swift` | A pasted or scanned link fills the form and waits for Connect. There is no warning about someone else's account. |
| Session token kept and resumed | bh | has | `Servers/KeychainStore.swift` | Keychain, per server. |
| Held session: "Sign in with your passkey to continue" | bh | missing | | Depends on passkeys. |
| Refused resume shows Signed out with the server's message | bh | has | `Kit/ConnectionState.swift`, `Rooms/RoomListView.swift` | |
| Add passkey to an account | bh | missing | | |
| Add email to an account | bh | missing | | UX.md 3.11 plans it. |
| Add external sign-in | bh | missing | | |
| "Add a sign-in" nudge for token-only accounts | bh | missing | | |
| Sign out | bh | has | `Rooms/RoomListView.swift` (confirmation) | |
| Passkey failure diagnostics in the console | #43 | N/A-iOS | | Applies once passkeys land; then log to `os_log`. |
| Read-only guest: Sign in bar in place of the composer | #45, `ext:permissions` | has | `Timeline/TimelineView.swift` (`ReadOnlyPrompt`) | |
| Disconnect from the server pane, without forgetting the session | #177 | missing | | Ladle has Remove Server only. |
| Connect to another server… | #177 | has | `Servers/ServerListView.swift` (Add Server) | |

## 4. Server pane and profile

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Sidebar head: server avatar, title, host | #138 | has | `Servers/ServerListView.swift`, `Rooms/RoomListView.swift` title | |
| Server pane: description, connection dot, who you are, address with copy, protocol version | #177 | has | `Profile/ServerPaneView.swift`, `Kit/ServerPane.swift` | From the room list's title, and on iPad the sidebar head. Connect to Another Server… opens Connect; Disconnect signs out of this server after a confirmation, since Ladle keeps every server. |
| Edit profile from the server pane | #177 | has | `Profile/ServerPaneView.swift`, `Rooms/RoomListView.swift` | Opens You. |
| Profile bar: avatar, name, status line or "notifications paused", gear | #177 | partial | `Rooms/RoomListView.swift` (`profileBar`), `Kit/Profile.swift` (`profileLine`) | Avatar with your dot, name, your status in words or else `@user_id`, and a gear that opens You. No paused line until pause exists (gap 7). |
| Edit display name (`me {name}`) | bh | has | `Profile/YouView.swift`, `Kit/Profile.swift` (`save`) | Says when the server kept another name or declined it. |
| Edit bio (`ext:bio`) | #115 | has | `Profile/YouView.swift`, `Kit/Profile.swift` (`Bio`, `save`) | Cleaned as `cleanBio`, 250 code points, `too_large` explained. |
| Upload avatar (`/avatar` with an upload embed) | bh | has | `Profile/YouView.swift`, `Kit/ServerSession+Uploads.swift` | |
| Remove avatar (`me {avatar: ""}`) | bh | has | `Profile/YouView.swift`, `Kit/Profile.swift` (`removeAvatar`) | |
| "User ID assigned by server: @ada" | #177 | has | `Profile/YouView.swift` | |
| Revert and Save for name and bio | #177, #179 | has | `Profile/YouView.swift`, `Kit/Profile.swift` (`ProfileForm`) | |

## 5. Presence, status, and pause

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Status dots: online, idle, dnd, offline | #48 | has | `Design/People.swift` (`StatusDot`), `Kit/Timeline.swift` (`Presence`) | |
| Unknown status as a dashed placeholder with its value | bh | has | `Design/People.swift` (`StatusDot`), `Kit/Timeline.swift` (`Presence.unknown`, `words`) | A dashed ring; the words say "Unknown status: away-ish". |
| Status picker: Online, None, Do not disturb, Invisible per `server.status` | #48 | has | `Profile/YouView.swift`, `Kit/Profile.swift` (`StatusChoice`, `chooseStatus`) | Your chosen status is read only from `you`. |
| Server answered another status: callout | bh | has | `Profile/YouView.swift`, `Kit/Profile.swift` (`StatusAnswer`) | An optional one it answered otherwise for is not offered again. |
| Idle after 5 minutes, `status {idle}` reporting | #52 | missing | `App/RootView.swift` | UX.md 4.1 wants `{idle: 0}` on background. Not sent. |
| Pause notifications (1 h, 8 h, until tomorrow, until I resume) | #48 | missing | | |
| Pause set elsewhere shows here | bh | missing | | |
| Last seen on the profile card and member tooltip | #126 | partial | `Profile/ProfileCardView.swift`, `Kit/UserProfile.swift` (`LastSeen`) | On the card, as `lastSeen`. No member-list tooltip (iOS has no hover); apron-web's local `sawOffline` floor is not kept. |
| Do not disturb silences this device | bh | missing | | Depends on notifications. |

## 6. Rooms list (sidebar)

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Joined rooms listed | bh | has | `Rooms/RoomListView.swift` | |
| Unread bubble, mention `@` bubble in orange | #17, #76 | has | `Rooms/RoomListView.swift` (`RoomRow`, `UnreadCount`) | |
| Room row shows the description line | #73 | has | `Rooms/RoomListView.swift` | |
| Open row: neutral fill and accent bar | #76 | has | `Rooms/RoomListView.swift` | |
| Rooms order kept on device, new rooms last | #151 | missing | `Kit/ServerSession.swift` (`roomTree`, by title) | Ladle sorts by title. |
| Drag a room to reorder (mouse, touch hold) | #151, #160 | missing | | iOS form: `onMove` or drag and drop in the list. |
| Alt+↑ and Alt+↓ move a room | #151 | missing | | iPad hardware keyboard. Depends on the row above. |
| Section headings fold to rooms with news, with "…" | #148 | missing | | |
| Folded rooms remembered | #150 | missing | | |
| Pick the open room again to fold its threads | #145 | missing | | |
| Private section with faces of who it's with | #123 | missing | | Private rooms show among Rooms with a lock. |
| Private room named for its members ("Dev, Mira", "You") | #123 | missing | `Kit/ServerSession.swift` (`title`) | An untitled room shows its `room_id`. |
| Other Rooms section with member count and Join | #74 | partial | `Rooms/RoomListView.swift` (`BrowseRoomsView`) | A Browse sheet, not a section. No member count or description. A tap on a row does not open it to read. |
| News from other rooms on the phone's back button | #84 | partial | `Servers/ServerListView.swift` | The server list shows unread per server. The room's back button has no tag. |
| Room row context menu | | partial | `Rooms/RoomListView.swift` (`roomActions`) | New Thread, Join, Leave. No Copy Link, Mute, or Mark as Read. |
| Leave by swipe | | has | `Rooms/RoomListView.swift` (`swipeActions`) | |
| Sidebar resize and collapse by drag or arrow keys | #59, #62 | N/A-iOS | | `NavigationSplitView` owns the column. |

## 7. Threads

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Threads under the open room on a guide line | #66, #73 | partial | `Rooms/RoomListView.swift` | Every known thread shows under every joined room, always. Web shows them under the open room, and only those with news elsewhere. |
| Joined threads most recently active first | #120 | missing | `Kit/ServerSession.swift` (`roomTree`) | Ladle sorts threads by title. |
| Thread row: title, description line, latest message, unread bubble | #73, #87 | has | `Rooms/RoomListView.swift` (`RoomRow`) | |
| Quiet threads step back (muted title) | #76 | partial | `Rooms/RoomListView.swift` | Weight changes with unread. Not verified in code: the muted look for quiet threads. |
| Other Threads heading, last active, "N more…" | #66, #74, #79 | missing | `Kit/ServerSession.swift` lists `not_joined` threads | Unjoined threads mix in with joined ones under the room, marked "Not joined". |
| Join a thread from its row | #74 | has | `Rooms/RoomListView.swift` (context menu) | |
| Leave a thread from its row without asking | #66 | partial | `Rooms/RoomListView.swift` | Leave asks first. |
| Read a thread without joining it | #102 | has | `Kit/ServerSession.swift` (`open`) | |
| Thread card in the room feed, with description and latest message | #87, #103 | has | `Timeline/TimelineView.swift` (`ThreadCard`) | |
| Thread card shows unread and private | #103 | has | `Timeline/TimelineView.swift` (`ThreadCard`) | |
| Start thread dialog: title and CommonMark Description | #71 | partial | `Rooms/RoomListView.swift` (`alert`) | Title only. No Description field. |
| Start thread from a message, with quote as Description, first reply links back | bh | missing | `Kit/MessageMenu.swift` | Not in the message menu. UX.md 3.6 plans it. |
| Thread opens at its latest reply, pages older on scroll | #91, shazow/apron#33 | has | `Kit/ServerSession.swift` (`loadOlder`) | |
| "N+ replies" on threads with older replies | bh | missing | | |
| A thread without a title is "Untitled" | bh | missing | `Kit/ServerSession.swift` (`title`) | Falls back to `room_id`. |
| Thread header: crumb back to its room | bh | partial | `Timeline/TimelineView.swift` toolbar | Back pops the stack. No crumb with the room name. |
| Private room's thread must come back private | bh | missing | | |

## 8. Room header and description

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Header title with lock for private | bh | has | `Timeline/TimelineView.swift` toolbar | |
| Pinned Description under the header, three lines, expand, × to put away | #91, #94, #117 | missing | | Description shows only in the rooms list. |
| Description button to pin it again | #117 | missing | | |
| ⋯ menu: Search local history | #137, #166 | missing | | |
| ⋯ menu: Copy link to room or thread | #112 | missing | `Timeline/TimelineView.swift` | Copy Link exists for messages only. |
| ⋯ menu: Mute and Unmute room or thread (bell-off button while muted) | #125 | missing | | No `status {mute, room_id}`. |
| ⋯ menu: Edit room or thread (title, description) | bh | missing | | Kit's `room_set` creates only. |
| ⋯ menu: Leave, after asking | bh | has | `Timeline/TimelineView.swift` | |
| Join button in the header of an unjoined room or thread | bh | has | `Timeline/TimelineView.swift` (`Join Room`) | Inside the ⋯ menu. |
| Members toggle | bh | has | `Timeline/TimelineView.swift` (`Members`, ⇧⌘M) | |
| Untitled private room header: faces, "only you and Bob can see this room" | #124 | missing | | |
| Plum wash on private room headers | #124 | missing | | |

## 9. Private rooms and direct messages

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Create a room with Private | #123 | missing | `Rooms/RoomListView.swift` | New Room asks for a title only. |
| Private room that comes back public is refused | bh | missing | | |
| New private conversation: people picker with chips, Name for groups | #123, #129 | missing | | UX.md 4.8 lists it as left out. |
| Message on a profile card opens or starts the DM | #123 | missing | | |
| "Already talking · Open" | #123 | missing | | |
| Private room limit "2 of 5" with Leave list (`ext.settings.private_rooms`) | #123 | missing | | |
| Private room intro card at the start of history | #124 | missing | | |
| "You were added to this private room." banner with Mute, Leave | #128, #165 | missing | | |
| Leave a private room warns it can't be rejoined | bh | has | `Rooms/RoomListView.swift` (confirmation text) | |
| Lock beside private names | bh | has | `Design/Components.swift` (`Lock`) | |

## 10. Members and profiles

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Member list with Online and Offline sections and counts | #99, #101 | has | `Timeline/MemberList.swift` | |
| Sections fold, remembered | bh | missing | | |
| No status stays under Online; one list with no heading without presence | bh | missing | `Kit/Timeline.swift` (`memberSections`) | A member with no status counts as offline, and headings always show. |
| Sort online, idle, dnd, unknown, offline, none | bh | partial | `Kit/Timeline.swift` | Two sections, by name within. |
| Offline members dimmed | #101 | has | `Timeline/MemberList.swift` | |
| `member_count` with a truncated list says so | bh | missing | | |
| Role badges, names first, "BOT +2" overflow | #39, #77, #131 | partial | `Design/People.swift` (`RoleBadges`) | Badges that don't fit are dropped. No "+2" count on the last one. |
| `@user_id` beside a name only when another user shares it | #82 | has | `Kit/UserDirectory.swift` | |
| One entry per user after a `user_id` change, aliases | #81, #83 | has | `Kit/UserDirectory.swift` (`rename`) | |
| Initials on a hue hashed from `user_id` | bh | has | `Design/People.swift` (`Avatar`) | |
| Profile card: avatar, name, `@user_id` with copy, roles, "(you)", same-name warning, bio, in-room | #47, #115, #116 | has | `Profile/ProfileCardView.swift`, `Kit/UserProfile.swift` | A sheet. "Not among the recently active members" waits for `member_count` (gap 33). |
| Profile card: Message, Mention, Add to room | #123 | partial | `Profile/ProfileCardView.swift`, `Kit/UserProfile.swift` (`addMember`), `Kit/DraftField.swift` (`mention`) | Mention and Add to room. Message waits for private conversations (gap 10). |
| Tap a mention chip, name, avatar, or member to open the profile | #149, #153, #161 | has | `Timeline/MessageRow.swift`, `Timeline/MemberList.swift`, `Timeline/TimelineView.swift`, `Kit/MessageText.swift` | A chip links `apron:?user=`; a link's `user` opens the card too. |
| Member row menu: Profile, Direct message, Remove from room | #152, #161 | missing | | |
| Add member (+ in the header, people picker) | #129 | missing | `Kit/Permissions.swift` reads `add_members` | No `room_join` with a `user_id`. |
| Remove from room, after a confirm | #152 | missing | | |
| Member list hides typing and connection status | bh | has | `Timeline/MemberList.swift` | |
| Member list resize and collapse | bh | N/A-iOS | | Sheet on iPhone, inspector column on iPad. |

## 11. Timeline and message rendering

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Anchored at the bottom, stays put when the composer grows | #64 | has | `Timeline/TimelineView.swift` | |
| Sender groups, day dividers, floating day | #65 | partial | `Kit/Timeline.swift` (day pills) | Day pills show. No floating day while scrolling. |
| New divider above the first unread | #100 | has | `Kit/ServerSession.swift` (`newLine`) | |
| Open at the New divider, not the latest | #100 | missing | AGENTS.md "A room opens at its latest message" | Needs on-device scroll checks. |
| Jump bar to latest, rust with Jump to mention | #28 | has | `Timeline/TimelineView.swift` (`JumpBar`) | |
| Mentioned row tinted with a rust rule | bh | has | `Timeline/MessageRow.swift` | |
| Mention pulse once on arrival | bh | missing | | |
| Edited label | bh | has | `Timeline/MessageRow.swift` | |
| Moved from #room | #54 | has | `Timeline/MessageRow.swift` | |
| Hide deleted messages from the feed (fork) | fork "Hide deleted messages from the feed" | has | `Kit/ServerSession.swift` (`timeline`) | |
| Reply quote as one line with a bent spine, tap to jump, across rooms | #98 | has | `Timeline/MessageRow.swift` (`ReplyQuote`) | |
| Markdown quoted as plain text | #146 | has | `Kit/MessageText+Plain.swift` | |
| CommonMark blocks: headings, lists, blockquotes, fenced code | #12 | partial | `Kit/MessageBlocks.swift`, `Timeline/MessageBlocksView.swift` | Every block renders; fenced code has no syntax highlighting. |
| GitHub tables and strikethrough | #12 | partial | `Kit/MessageText.swift` | Strikethrough is inline and may render. Tables do not. |
| Syntax-highlighted code blocks | #16 | missing | | |
| Raw HTML as text | bh | has | `Kit/MessageText.swift` | |
| Bare URL linking | #6 | has | `Kit/MessageText.swift` | |
| `@user_id` as a chip with current name | bh | has | `Kit/MessageRowModel.swift` (`MentionKey`) | |
| `#room_id` as a chip that opens the room | bh | has | `Kit/MessageText.swift` (`RoomReferenceKey`) | |
| `@&role` as a role chip that reads `@role` and opens nothing, never in code, also in reply quotes and previews | #181 | has | `Kit/MessageText.swift` (`RoleMentionKey`), `Kit/MessageText+Plain.swift`, `Timeline/MessageRow.swift` (`styled`) | Any role, known or not. Denim on denim-soft with a dotted denim rule in place of the web's 1 px ring, which a run of `Text` cannot draw. |
| A message mentions you only when `body.mentions` lists you, never for a role you hold | #181 | has | `Kit/Timeline.swift` (`mentions`), `Kit/MessageRowModel.swift` | Badges, the tint and mention counts follow the list, as the web and push do. |
| Bidi overrides dropped, text isolated in its own direction | #138 | has | `Kit/TextDirection.swift` | |
| Join and leave lines ("Ada and Bob joined · Carol left") | #170 | missing | | UX.md 4.8 left it out for guest churn. |
| Rename lines ("Room renamed to Ops") | #170 | missing | | |
| System senders as quiet lines; `~private`, `~room`, `~server` as notice cards | bh | has | `Timeline/TimelineView.swift` (`Callout`), `Kit/MessageMenu.swift` (`NoticeMenu`) | |
| Transient notices for the session, never stored | bh | has | `Kit/ServerSession.swift` (`notices`) | |
| Welcome notice in the first room | bh | partial | `Servers/ConnectView.swift` | The welcome shows in the Connect sheet, not in the first room. |
| Copy button on a notice's code block | bh | has | `Timeline/TimelineView.swift` (`noticeActions`) | Copy each code span from the menu. |
| Show QR code for a sign-in link in a `~private` notice (fork) | fork "Show a sign-in link from a ~private notice as a QR code" | missing | | Ladle scans QR codes but cannot show one. Useful to sign in a second device. |
| Typing indicator, others' | bh, `TypingIndicator.svelte`, `RoomHeader.svelte` | has | `Kit/ServerSession+Typing.swift`, `Timeline/TypingIndicator.swift` | On iPhone a centered denim line under the navigation bar ("Ada is typing…", "2 people are typing…"), the words of the web's header subtitle under 720 px, kept out of the bar so its centered title never moves; on iPad a line with three bobbing dots above the composer ("Ada and Bram are typing…", "Several people are typing…"), its row kept so nothing moves. Reduce Motion stills and dims the dots. Held at most 300 s; a message from them or `typing: 0` ends it. |
| Send typing (`activity typing: 15`, refresh 12 s) | bh, `client.ts` `sendTyping` | has | `Kit/ServerSession+Typing.swift` (`composerChanged`) | 15 s, again no sooner than 12 s, `typing: 0` after 5 s untouched, nothing after a message. Only with `activity`; `ext:settings` does not govern typing (the web reads only `read_cursors` and `private_rooms` from it). |
| Start-of-history card for private rooms | #124 | missing | | |
| Placeholder while a room loads its first page | #173 | missing | `Timeline/TimelineView.swift` | No placeholder rows. |
| iOS overscroll jitter, keyboard fit | #97, #165 | N/A-iOS | | Native scrolling and keyboard avoidance. |

## 12. Message actions

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Long press opens the actions on touch | #139 | has | `Timeline/TimelineView.swift` (`contextMenu`) | Native context menu. |
| Reply | bh | has | `Timeline/TimelineView.swift` | |
| React (full picker) | #10 | has | `Timeline/ReactionPicker.swift` | Quick six, then the emoji keyboard and custom emoji. |
| Start thread | bh | missing | `Kit/MessageMenu.swift` | |
| Edit (own) | bh | has | `Kit/DraftField.swift` (edit mode) | |
| Edit keeps and edits embeds as tiles, rename uploads | #70 | missing | | Edit changes text and mentions only. |
| Select (enter select mode) | #14, #54 | missing | | |
| Copy text | bh | has | `Kit/MessageMenu.swift` | |
| Copy link | #112 | has | `Kit/MessageMenu.swift` | Web form. |
| Remove reply reference | bh | missing | | |
| Delete with confirm | bh | has | `Timeline/TimelineView.swift` | |
| Move to thread or back to room | #54 | has | `Kit/MessageMenu.swift` (`moveDestinations`) | One message at a time. |
| Second tap puts the toolbar away | #118 | N/A-iOS | | The context menu dismisses natively. |
| `x` on a message selects it | bh | missing | | iPad hardware keyboard. Depends on select mode. |

## 13. Select mode, move, and copy

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Select mode with shift-click range | #14, #54 | missing | | iOS form: an Edit mode with checkmarks and a drag-select. |
| Selection bar: count, Move to thread, New thread, Cancel | #54, #175 | missing | | |
| Move all or nothing; anyone's with `move_any` | #54 | partial | `Kit/ServerSession.swift` (`move`, `mayMove`) | Single message only. |
| Move to a new thread | #54 | missing | | |
| Moved messages' authors added to the thread | #95 | missing | | |
| Copy the selection as a Markdown log | #164 | missing | | |
| Copy quotes what a reply answers, marks cut snippets, reactions, omitted notes | #168, #172 | missing | | |

## 14. Composer

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Enter sends, Shift+Enter new line (hardware keyboard) | bh | has | `Timeline/ComposerView.swift` (`onKeyPress`) | |
| Enter makes a new line on a phone keyboard | #60 | has | `Timeline/ComposerView.swift` | |
| Focus stays after Send | #97 | has | `Timeline/ComposerView.swift` | |
| One-line placeholder with the room name | bh | has | `Timeline/ComposerView.swift` (`placeholder`) | |
| `@` mention picker over members, then recent senders | bh | has | `Kit/DraftField.swift`, `Timeline/ComposerView.swift` | |
| Picked mention as a name chip; Backspace turns it back to text | bh | partial | `Kit/DraftField.swift` | `@Name` text plus a mention entry. No chip in the field. |
| Typed `@name` collapses to a mention when unique | bh | partial | `Kit/DraftField.swift` | Not verified in code: that typed names count. |
| `#` room autocomplete with chips | bh | has | `Kit/RoomMentions.swift` | Inserts `#room_id`, no chip in the field. |
| `:` shortcode autocomplete for standard emoji | bh | partial | `Kit/DraftField.swift` (`.emoji`) | Custom emoji only. Standard emoji come from the system keyboard. |
| Emoji button that inserts at the caret | bh | has | System emoji keyboard | iOS-native form. |
| Mentions and autocomplete also in the editor | #159 | has | `Kit/DraftField.swift` | |
| `@` suggests people and roles; `@&` roles only, with how many each reaches | #181 | has | `Kit/RoleMentions.swift`, `Kit/DraftField.swift` (`mentionSuggestions`), `Timeline/ComposerView.swift` (`MentionPicker`) | Roles others in the room hold, most held first; the exact role after the exact person; roles keep 3 of the 8 rows when people fill the list. Ladle's people still match on contains, not prefix. |
| A role sends as `@&role` and lists every other holder in `body.mentions`, in draft order | #181 | has | `Kit/DraftField.swift` (`sentMentions(holders:)`, `insert(role:)`) | No chip in the field: the text holds `@&role` as sent, so a typed one counts too, and Backspace edits it as text. An edit recomputes the holders at save. Only as complete as the member list the server sent. |
| Reply bar "Replying to" | bh | has | `Timeline/ComposerView.swift` | |
| Command mode: Command tag, monospace, Run | bh | partial | `Timeline/ComposerView.swift`, `Kit/CommandHelp.swift` | Sends `command` and lists commands. No Command tag, monospace line, or Run label. |
| `/help` lists the server's commands | bh | has | `Kit/CommandHelp.swift` | Ladle lists them as you type, a superset. |
| `/nick`, `/join`, `/leave`, `/topic`, `/kick`, `/invite` handled by the client | bh | missing | | All go to the server. UX.md 3.7 chose that. |
| `//` posts a message starting with `/` | bh | has | `Kit/DraftField.swift` | |
| Failed command gives the draft back | bh | partial | `Kit/ServerSession.swift` outbox | Not verified in code: the draft returns. |
| Drafts per room | bh | has | `Kit/Drafts.swift` | See section 2. Reply keeps the text; an edit sits beside the draft and gives it back. |
| Link previews above the composer with × to drop | #11, #19 | missing | | |
| Rate limit: Send counts down under "Sending is paused" | #109 | missing | | Kit waits. No countdown shows. |
| Uploads are paused notice (`ext:limits` upload) | #109 | partial | `Kit/ServerSession.swift` | Kit pauses uploads. No notice. |

## 15. Links, deep links, and place cards

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Open `link.apron.chat` and `apron:` links in the app | #112, #126 | has | `Kit/ApronLink.swift`, `Kit/LinkRoute.swift`, `App/RootView.swift` | |
| Strict place reading (A.4 shapes, first value wins, reachable server) | #126 | has | `Kit/ApronLink.swift` | |
| Link to another server opens the connect screen first | bh | has | `Kit/LinkRoute.swift` | |
| Message link scrolls to the message and highlights it | #86 | has | `Kit/ServerSession.swift` (`reveal`), `Timeline/MessageRow.swift` | |
| User link opens the profile | #86 | partial | `App/RootView.swift` | Opens the member list. No profile card. |
| Apron links as chips that say what they are ("Message in #general") | #119 | missing | `Kit/MessageText.swift` | They show as plain links. |
| Other-server link as an outlined globe chip | #119 | missing | | |
| Place cards for messages, rooms, threads (up to 3) | #119 | has | `Kit/PlaceCards.swift`, `Timeline/PlaceCardView.swift` | |
| Skip a link preview that duplicates a place card | #155 | has | `Kit/PlaceCards.swift` (`previews`) | |
| Copy and share links in the web form | #112 | has | `Kit/ApronLink.swift` (`outbound`) | Plus `ShareLink`. |
| Every web link opens outside the app | bh | has | `Kit/MessageText.swift` | Safari. |
| Modified click opens link.apron.chat in a new tab | bh | N/A-iOS | | No modified click. |

## 16. Embeds and uploads

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Attach with a file picker | #49 | has | `Timeline/Attachments.swift` (Choose File) | Plus photos and camera. |
| Drop files on the conversation | #49 | has | `Timeline/TimelineView.swift` (`dropDestination`) | |
| Paste files | #49 | partial | `Timeline/ComposerView.swift` (Paste Image) | Images only. |
| Voice clips | #96 | has | `Timeline/VoiceRecorder.swift` | |
| Staged files with thumbnails, players, file cards, × | #49 | has | `Timeline/Attachments.swift` | |
| "Preparing…" while an image shrinks, then its new size | #35 | has | `Timeline/Attachments.swift:151` | |
| Rename a file before sending | #70 | missing | `Timeline/ComposerView.swift` (`rename` is internal) | |
| Rename an upload after sending (in the editor) | #70 | missing | | |
| Fit to `ext:media` types and limits | #35 | has | `Kit/UploadPlan.swift`, `Kit/MediaLimits.swift` | |
| Pending card with progress | bh | has | `Timeline/EmbedViews.swift` | |
| "Upload failed" with reason; 10-minute stale pending fails | #136 | partial | `Kit/ServerSession+Uploads.swift` | A failed write becomes a Not sent item. Not verified in code: the 10-minute rule for others' uploads. |
| Image, video, audio players for uploads | bh | has | `Timeline/EmbedViews.swift` | |
| Full-screen image viewer, paging, Open original | #53 | has | `Media/MediaViewer.swift` | |
| Remove an embed from a sent message (×, asks for uploads) | #13, #20 | missing | | |
| `og` link card | bh | has | `Timeline/EmbedViews.swift` | |
| `og.video` and `og.audio` play in the card (fork) | fork "Play og.video and og.audio in link preview cards" | has | `Timeline/EmbedViews.swift` | |
| Fallback card with kind and url or text | bh | has | `Timeline/EmbedViews.swift` | |
| Stream embed read live, Live badge | shazow/apron#26 | missing | `Kit/Embed.swift` | |
| Finished stream `text` shown | bh | partial | `Timeline/EmbedViews.swift` | Shows as the fallback card's text. |
| `embed:terminal` ANSI colors, carriage-return overwrite | shazow/apron#26, `ui/terminal.ts` | missing | | |
| `iframe` paused until Load live view, sandboxed | bh | missing | `Timeline/EmbedViews.swift` | Fallback card. Needs a sandboxed `WKWebView`. |
| `html` embed sanitized and inserted | bh | missing | `Timeline/EmbedViews.swift` | Fallback card. |
| Sender-built link previews (GitHub, YouTube, X, Bluesky, Wikipedia) sent as `link` embeds | #11, #122 | partial | `Kit/LinkPreviews.swift`, `Timeline/FetchedLinkCard.swift` | Ladle fetches previews for itself with LinkPresentation. Its outgoing messages carry no `og`, so others see no card. |
| Avatar picker accepts any image | #92 | has | `Rooms/RoomListView.swift` (PhotosPicker) | |

## 17. Media loading

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Media from the server's origin and `ext:media` origins | #111 | has | `Kit/Embed.swift` (`MediaPolicy`) | |
| Media gate: everything else waits for a click (Load) | #163 | has | `Kit/MediaGate.swift`, `Media/MediaAskTile.swift` | |
| Always load adds the site to Trusted origins | #163 | has | `Media/MediaAskTile.swift` | |
| The Load tile shows the media's full URL; Always load names its host | #186 | has | `Media/MediaAskTile.swift` | Two lines, cut in the middle; VoiceOver reads the whole URL. |
| Preferences, Media: Server and trusted sites, or Any site; Trusted origins field | #137, #163 | has | `Servers/PreferencesView.swift` | |
| Custom emoji and avatars from untrusted sites wait or fall back | #163 | has | `Kit/MediaGate.swift` (`.avatar`) | |
| HTML embeds never load `srcset`, `background`, `ping` | #163 | missing | | Depends on `html` embeds (section 16). Build it with them. |
| Streams only from the server's origin | bh | missing | | Depends on live streams (section 16). Build the origin rule with them. |
| Images in a link wait after the link | #163 | partial | | A linked image shows as its link with the alt text: Foundation drops the image URL. |

## 18. Reactions and custom emoji

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Reaction chips with count, yours highlighted | bh | has | `Timeline/MessageRow.swift` (`ReactionBar`) | |
| Tap a chip to toggle | bh | has | `Timeline/MessageRow.swift` | |
| Who reacted, on long press | #90 | has | `Timeline/MessageRow.swift` (chip `contextMenu`) | |
| Picker names the message it reacts to ("React to Ada") | bh | missing | `Timeline/ReactionPicker.swift` | The sheet is titled "Add Reaction" and does not name the message. |
| ❤ and ❤️ as one chip | #144 | has | `Kit/ReactionEntry.swift` | |
| Tombstones show no reactions | bh | has | `Kit/ServerSession.swift` (`timeline` drops tombstones) | |
| Custom emoji in text, descriptions, welcome (`ext:emoji`) | bh | has | `Timeline/CustomEmojiViews.swift`, `Kit/CustomEmoji.swift` | |
| Custom emoji reaction keys, dashed placeholder when unknown | bh | has | `Timeline/CustomEmojiViews.swift` (`ReactionGlyph`) | |
| Custom emoji in the picker by category | bh | has | `Timeline/ReactionPicker.swift` | |
| Browsable full emoji picker | #10, shazow/apron#40 | has | System emoji keyboard | iOS-native form. |

## 19. Unread, read cursors, and read positions

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Read position per device and account | #100 | has | `Kit/ReadPositions.swift` | |
| Send `read_message_id`, throttled | #132 | has | `Kit/ServerSession.swift` (`markRead`, 5 s) | Web throttles at 10 s. |
| Read cursors from other devices | bh | has | `Kit/ServerSession.swift` (`activity`) | |
| `read_cursors: false` sends none | #130 | has | `Kit/ServerInfo.swift` (`keepsReadCursors`) | |
| Unread kept through a reload | #128 | partial | `Kit/ReadPositions.swift` | Positions persist. Messages don't, so counts rebuild only after loading. |
| Count only where the server keeps cursors | #130 | has | `Kit/ServerSession.swift` (`unreadCount`) | |
| A room someone added you to counts from your join | bh | missing | | |
| Unread in the tab title | bh | N/A-iOS | | The app icon badge is the iOS form (section 20). |

## 20. Notifications and push

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Notify me about: Mentions, Replies, All in private rooms, All in joined rooms | #48 | missing | | Planned with push (APNs and a §4.9.2 relay, post-v1). |
| One Notifications switch per device | #57 | missing | | |
| Local notifications while the app is open but not in front | #48 | missing | | iOS form: foreground `UNUserNotificationCenter` alerts for other rooms. |
| Push while closed (`push_register`) | #48 | missing | | APNs relay. Never polling. |
| Offer notifications at the first mention, or at sign-in in an installed app | #61, #93 | missing | | |
| Send a test notification | bh | missing | | |
| Tap a notification to open the room | bh | partial | `App/ReminderNotifications.swift` | Works for Remind Me only. |
| Close notifications when read here or on another device | #52, #154 | missing | | |
| App badge from `unread` | bh | missing | | |
| Mention chime and tab title flash | bh | N/A-iOS | | Notification sounds and the badge cover it. |
| Muted rooms and threads don't notify | #125 | missing | | Depends on mute. |
| "Only while open" for scopes the server doesn't push | bh | missing | | |
| Alert for this server instead (one subscription) | bh | N/A-iOS | | One APNs token per device. Each server registers it. |

## 21. Search

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Search local history, as you type | #137 | missing | | UX.md 4.8 left it out because history isn't kept. It searches kept and loaded messages. |
| `user:` and `room:` filters with suggestions | #137 | missing | | |
| Starts narrowed to the open room | #137 | missing | | |
| Open a result where it is, paging back | #137 | missing | `Kit/ServerSession.swift` (`reveal`) exists | |
| Note on how far back history is kept, linking to History | #166 | missing | | |
| Search rooms by name in the rooms list | | missing | | UX.md 3.1 plans `.searchable`. Not built. |

## 22. Export and archive

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Export loaded chats as `.jsonl` (ARCHIVE.md) | #135 | missing | | iOS form: a `ShareLink` or file exporter. |
| Include private rooms only when asked | #171 | missing | | |
| Open an export read-only (`/archive`) | #135 | missing | | iOS form: open a `.jsonl` from Files. |
| Ask before loading images an export names | #135 | missing | | |
| `ext:archive` (EXT.md §10) | EXT.md §10 | missing | | Depends on export and archive. |

## 23. Preferences and appearance

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Preferences dialog with Profile, Notifications, Appearance, Media, History | #23, #171, #177 | missing | | Ladle has a Settings.bundle page with Show Link Previews only. |
| Theme: light, dark, or system | #23 | missing | | Ladle follows the system. Add an override. |
| Fonts for interface, chat, and code (experimental) | #23 | missing | | Web marks it experimental, to become themes. |
| Settings kept on device, applied across tabs | bh | N/A-iOS | | One app process. |

## 24. Permissions, settings, and limits

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| `ext:permissions`: write, add_members, move_any | #111, #121 | has | `Kit/Permissions.swift` | `add_members` is read but nothing uses it. |
| `ext:settings`: read_cursors | #111 | has | `Kit/ServerInfo.swift` | |
| `ext:settings`: private_rooms limit | #123 | missing | | |
| `ext:limits` write and upload pauses | #109 | partial | `Kit/ServerSession.swift` | Kit holds requests. No countdown UI. |
| `retry_after` holds `history` and `message` | #109 | has | `Kit/ServerSession.swift` | |
| Reaction, join, leave refused during a pause with a toast | #109 | missing | | |
| Only write `ext` to servers with `ext` | bh | partial | `Kit/ServerSession.swift` (`save`) | An edit resends the stored `ext` with no `ext` capability check. Ladle never writes new `ext`. |

## 25. Keyboard shortcuts

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Enter, Shift+Enter in the composer | bh | has | `Timeline/ComposerView.swift` | |
| Escape closes pickers, dialogs, the editor | bh | has | `Timeline/ComposerView.swift` (`.cancelAction`) | |
| ↑ ↓ Tab Enter in mention, room, emoji, command lists | bh | missing | `Timeline/ComposerView.swift` | Hardware keyboard on iPad. Touch picks work. |
| Ctrl or ⌘F opens Search local history | #137 | missing | | Depends on search. |
| `x` selects a message | bh | missing | | Depends on select mode. |
| Alt+↑ and Alt+↓ move a room | #151 | missing | | Depends on room order. |
| ← → in the image viewer | #53 | partial | `Media/MediaViewer.swift` | Swipe pages. No arrow keys. |
| Arrow keys resize the side panels | #59 | N/A-iOS | | No resizable columns. |
| Context menu key on a chip or member | bh | N/A-iOS | | Secondary click opens the same menu on iPad. |

## 26. Accessibility and layout

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Screen-reader labels for rows, statuses, pickers | #105, `e2e/a11y.spec.ts` | has | `Rooms/RoomListView.swift`, `Timeline/MemberList.swift` (composed labels) | |
| Right-to-left layout, mirrored lists | #138 | has | SwiftUI layout direction, `App/RootView.swift` | `Kit/TextDirection.swift` covers the text rows. |
| Reduced motion | bh | has | `Design/Apron.swift` (`Motion`) | |
| Phone layout with the rooms list as its own pane | #85 | has | `App/RootView.swift` | |
| Wide layout with member column | bh | has | `App/RootView.swift`, `Timeline/TimelineView.swift` (inspector) | |
| 16 px minimum field text so Safari doesn't zoom | #97 | N/A-iOS | | Dynamic Type. |

## 27. Install, PWA, and preview

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Installable PWA with a service worker | #8 | N/A-iOS | | Ladle is the native app. |
| Add to Home Screen offer with per-browser steps | #167 | N/A-iOS | | |
| Install app in Preferences | bh | N/A-iOS | | |
| `/__preview` in-memory server | bh | has | `Kit/PreviewServer.swift`, `Kit/PreviewFixtures.swift` | Development only, for the LadleShots renderer. |
| Link preview image and OpenGraph tags for the site | #142 | N/A-iOS | | A web page's own meta tags. |

## Ladle only

These have no apron-web counterpart. They stay.

- Several servers at once, with unread and mentions per server (`Servers/ServerListView.swift`).
- An outbox that queues sends while offline, with Retry and Delete (`Kit/ServerSession.swift`).
- Remind Me on a message, as a local notification (`Kit/Reminders.swift`, `Timeline/ReminderViews.swift`).
- Select Text on a message or notice (`Timeline/SelectTextSheet.swift`).
- The server's commands listed as you type a slash command (`Timeline/ComposerView.swift`, `CommandSuggestions`).
- A byte counter near the message text limit (`Kit/TextLimit.swift`).
- The camera as an attachment source, and Paste Image (`Timeline/Attachments.swift`).
- Device-side link previews through LinkPresentation, behind a setting (`Timeline/FetchedLinkCard.swift`).
- A QR scanner that fills in a server and token (`Servers/QRScannerView.swift`).
- Share Apron links through the share sheet (`ShareLink` in `Timeline/TimelineView.swift`).
- Frame and request limits checked before sending: 16 KiB frames, 128-byte ids, 8 requests in flight (`Kit/Connection.swift`).
- Close codes acted on: stop on revoked credentials, wait on 1013 (`Kit/ServerSession.swift`).
- New Room offered only where the server permits it (`Kit/ServerSession.swift`, `mayCreateRooms`).
- ⇧⌘M toggles Members, and ⌘Return always sends (`Timeline/TimelineView.swift`, `Timeline/ComposerView.swift`).

## Gaps, most user-visible first

Sizes are rough. S is a day or less. M is a few days. L is a week or more, or needs outside work such as a relay or associated domains. Items lower down often depend on items above them.

1. **Code highlighting.** Every markdown block renders since deac4e3; fenced code still has no syntax highlighting. S.
2. ~~**Profile card.**~~ Done (`Profile/ProfileCardView.swift`), but for Message, which comes with item 10.
3. ~~**Your profile and status.**~~ Done: You (`Profile/YouView.swift`) edits the name, bio and avatar and picks a status, with the server's answer.
4. ~~**Drafts per room.**~~ Done (`Kit/Drafts.swift`): text, mentions, reply target and ready files per room and thread, kept across a relaunch.
5. ~~**Typing.**~~ Done (`Kit/ServerSession+Typing.swift`, `Timeline/TypingIndicator.swift`): sends `activity typing` as the web does, and shows others typing in the header on iPhone and above the composer on iPad.
6. **Notifications and push.** Local alerts for other rooms while open, then APNs push through a §4.9.2 relay. Add Notify me about scopes, the per-device switch, the first-mention offer, the app badge, tap to open, closing notifications once read, and a test notification. Push, never polling. L.
7. **Mute and pause.** Mute a room or thread from its header and row (`status {mute, room_id}`), show the bell-off state, and add Pause notifications. These matter on other devices even before Ladle notifies. M.
8. **Threads.** Start thread from a message (title from its first line, quote as Description, first reply links back). Add a Description field to New Thread. Add an Other Threads heading with last active times. Order joined threads by activity. Show threads only under the open room, plus those with news. Name untitled threads "Untitled". Show "N+ replies". M.
9. **Room header.** Pin the Description under the header with expand and dismiss. Add Edit room or thread (`room_set` title and description), Copy link to the room, and Mute to the ⋯ menu. M.
10. **Private rooms and direct messages.** Create a room with Private. Add New private conversation with a people picker. Add Message on the profile card. Add a Private section with faces. Name untitled private rooms for their members. Add the intro card, the "You were added" banner, and the private room limit. L.
11. **Kept view and local history.** Cache rooms and recent messages on disk so a relaunch shows them at once. Keep history with Retention, delete it on sign-out, and page older messages from the device first. L.
12. **Join, leave, and rename lines.** Show them in the timeline, netted per user, with the 20-user baseline rule. S.
13. **Open at the New divider.** Land on the divider instead of the latest message. Needs a device to verify the scroll. S.
14. **Member management.** Add member with a people picker, Remove from room with a confirm, and the member row menu (Profile, Direct message, Remove). M.
15. **Select mode.** Select several messages, move them to a thread or a new thread, add authors to the thread, and copy them as a Markdown log with quotes, cut marks, and reactions. M.
16. **Search local history.** As-you-type search with `user:` and `room:`, narrowed to the open room, opening results in place. Also search rooms by name. Depends on item 11. M.
17. **Message editing with embeds.** Edit shows embeds as tiles with ×. Remove an embed from a sent message (asking for uploads). Rename a file before and after sending. Remove reply reference. M.
18. **Rooms list order and folding.** Keep room order on device with drag to reorder. Fold sections to rooms with news, remember folded rooms, and fold a room's threads when it is picked again. Make Browse Rooms show member counts and descriptions, and open a room to read before joining. M.
19. **Streams and terminal output.** Read a stream's `url` live with a Live badge. Render `terminal` with ANSI colors and carriage-return overwrite. Only from the server's origin. M.
20. **Apron link chips.** Draw Apron links as chips that say what they are ("Message in #general"), and other-server links as a globe chip. S.
21. **Rate limit feedback.** Count down "Sending is paused", show "Uploads are paused", and refuse reactions, joins, and leaves during a pause with the server's words. S.
22. ~~**Server pane.**~~ Done (`Profile/ServerPaneView.swift`). Disconnect signs out of that server, with a confirmation; a disconnect that keeps the saved session is not offered, since each server keeps its own connection.
23. **Reconnect feedback.** A floating pill with the 400/600/300 ms timing, "Checking for new messages…", the catching-up line under the header, and your own dot as a dashed ring while reconnecting. S.
24. **Idle reporting.** Send `status {idle}` on background and after 5 minutes without input, and `{idle: false}` on return. S.
25. **Sign-in QR display.** Show a sign-in link from a `~private` notice as a QR code behind a warning, so a second device can scan it. S.
26. **Sender-side link previews.** Build `og` for GitHub, YouTube, X, Bluesky, and Wikipedia links from their public APIs, and send it as a `link` embed with × to drop it before sending. Others then see the card. M.
27. **Passkeys.** Sign in, create an account, add a passkey, and resume a held session with a tap. Needs `webcredentials` associated domains. L.
28. **External sign-in and email extras.** External sign-in through `ASWebAuthenticationSession`. Add email to an account. Handle link `state` and the "Sign in or Add it" dialog with its warning. The "add a sign-in" nudge. M.
29. **`iframe` and `html` embeds.** A paused `iframe` with Load live view in a sandboxed `WKWebView`, and sanitized `html`, with the media gate's `srcset`, `background`, and `ping` rules. L.
30. **Client-side commands.** Handle `/nick`, `/join`, `/leave`, `/topic`, `/kick`, and `/invite` locally, as the web does, and give a failed command's draft back. S.
31. **Appearance.** A light, dark, or system theme override. A font choice, which the web marks experimental. S.
32. **Export and archive.** Export loaded chats as `.jsonl`, with Include private rooms, and open an export read-only from Files. M.
33. **Presence details.** An unknown status as a dashed placeholder with its value, the full status sort order, foldable member sections, and the `member_count` note. S.
34. **Composer details.** Standard emoji `:shortcode` autocomplete, mention chips in the field, and hardware-keyboard ↑ ↓ Tab Enter in every picker. S.
35. **Timeline polish.** The floating day while scrolling, the mention pulse on arrival, the 3-second wait for thread listings on first show, and the welcome notice in the first room. S.
36. **Keyboard shortcuts.** ⌘F for search, `x` to select, Alt+↑ and Alt+↓ to move a room, ← → in the image viewer, once the features behind them exist. S.
