# Ladle and apron-web feature parity

This is the backlog of record for parity with apron-web. The rule is that every apron-web feature exists in Ladle. The iOS form may differ. Ladle may do more. Nothing is left out.

The apron-web side is the fork at `forks/apron-web`, branch `homelab-3`. It carries upstream through #178 and #179, role mentions (#181), themes (#174), Preferences sections (#184), #186 and the Inactive threads section (#185), at 0811a18 for the design tokens, plus three fork features: hidden deleted messages, `og:video` cards, and the sign-in QR code. The Ladle side is `main` at the time of writing. The media gate and block markdown landed in 6273e57 and deac4e3.

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
| Restore the last view on relaunch | #56 | has | `App/RootView.swift` (`@SceneStorage` server and room), `Kit/ServerSession+History.swift` | Server and room come back, and their messages show from what was kept before the socket opens. |
| Kept view: rooms, last day of messages (150 per room), members, shown at once | #56, #102 | has | `Kit/KeptHistory.swift` (`KeptRestore`), `Kit/ServerSession+History.swift` | One file with the history below, not a second cache: under Don't Keep it holds the last day, 150 per room, as the web's view. The server's title and capabilities come with the connection, where the web keeps its `server` frame too. |
| Placeholder rooms and messages on a first visit, "Connecting…" then "Loading messages…" | bh | missing | | |
| History kept on device with Retention (a day, a week, 30 days, a year, forever, none) | #137 | has | `Kit/KeptHistory.swift` (`HistoryRetention`, `HistorySettings`), `Kit/Archive.swift`, `Servers/PreferencesView.swift` (`HistoryPreferences`) | `History/<server id>.jsonl` in ARCHIVE.md's form, excluded from backup. 30 days by default; cut by `log_id` where positions are times, as the web. A room not caught up since the cutoff starts over (`plannedRoom`). |
| Catch up from the kept checkpoint (`latest_log_id`, §4.3.5) | #137 | has | `Kit/ServerSession.swift` (`adopt`, `catchUp`) | Each kept room's checkpoint comes back, and the sign-in's catch-up pages forward from it. |
| Older pages from the device first, then the server | #137 | has | `Kit/ServerSession.swift` (`page`), `Kit/LogEntry.swift` (`slice`) | A relaunch shows the newest 50 entries (`RESTORE_WINDOW`); older pages come from the kept log, then the server once it runs out. |
| Preferences says how much is kept, and why it stopped | #137 | has | `Servers/PreferencesView.swift` (`HistoryPreferences`) | "Using about 12 MB." from the bytes last written, every server's together, where the web asks the browser's estimate; a full disk or a failed write says so in red. |
| History deleted on sign-out, kept apart per account and server | #137 | has | `Kit/ServerSession+History.swift` (`forgetKept`), `Kit/SessionStore.swift` (`remove`) | One account per server. Sign-out, a refused token, signing in as someone else and removing the server delete it. |
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
| Profile bar: avatar, name, status line or "notifications paused", gear | #177 | has | `Rooms/RoomListView.swift` (`profileBar`), `Kit/Profile.swift` (`profileLine`) | Avatar with your dot, name, "Paused until 14:30" with a bell-off while paused, else your status in words or `@user_id`, and a gear (with a small bell-off while paused) that opens Preferences at Profile for this server (`openPreferences`), as the web's. |
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
| Idle after 5 minutes, `status {idle}` reporting | #52 | has | `Kit/Attention.swift`, `Kit/ServerSession+Idle.swift`, `App/RootView.swift`, `App/InputWatcher.swift` | Idle after 5 minutes without a touch or typing, and in the background (before the session stops), as seconds since the last input; `idle: false` on the next input. |
| Pause notifications (1 h, 8 h, until tomorrow, until I resume) | #48 | has | `Kit/Mutes.swift` (`MuteChoice.pause`), `Kit/ServerSession+Mutes.swift` (`setPause`), `Profile/PauseSection.swift` | In Preferences > Notifications, with Resume and the server's words on a refusal. Not offered to a guest without a token to sign back in with, as the web's `canPause` (`mayMute`, `resumable`). |
| Pause set elsewhere shows here | bh | has | `Kit/ServerSession+Mutes.swift` (`applyStatus`) | The server's `status` sets it on every device, and again after each sign-in. |
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
| Private section with faces of who it's with | #123 | has | `Kit/PrivateRooms.swift` (`privateRoomTree`, `faces(of:)`), `Rooms/RoomListView.swift`, `Design/People.swift` (`Faces`) | Shown empty for its + where you may start one. |
| Private room named for its members ("Dev, Mira", "You") | #123 | has | `Kit/PrivateRooms.swift` (`PeopleTitle`), `Kit/ServerSession.swift` (`title`) | "Private room" while its members are unknown. |
| Other Rooms section with member count and Join | #74 | partial | `Rooms/RoomListView.swift` (`BrowseRoomsView`) | A Browse sheet, not a section. No member count or description. A tap on a row does not open it to read. |
| News from other rooms on the phone's back button | #84 | partial | `Servers/ServerListView.swift` | The server list shows unread per server. The room's back button has no tag. |
| Room row context menu | | has | `Rooms/RoomListView.swift` (`roomActions`), `Kit/RoomHeader.swift` (`markAllRead`, `link(to:)`) | Mark as Read, Copy Link, Mute or Unmute, New Thread, Join, Leave; Mark as Read on the leading swipe, Mute and Unmute on the trailing one. Mark as Read reads through the newest loaded message, else the room's `latest_log_id`. apron-web marks a room read as you read it and has no row menu; this is Ladle's own. |
| Leave by swipe | | has | `Rooms/RoomListView.swift` (`swipeActions`) | |
| Sidebar resize and collapse by drag or arrow keys | #59, #62 | N/A-iOS | | `NavigationSplitView` owns the column. |

## 7. Threads

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Threads under the open room on a guide line; under other rooms only joined ones with news, and the open one | #66, #73 | has | `Kit/Threads.swift` (`ThreadList`, `threadList(of:open:)`), `Rooms/RoomListView.swift` (`threads(of:)`) | The open room is the selected room, or the room of the selected thread. With nothing selected (the iPhone list over no room), every room shows only its threads with news. |
| Joined threads most recently active first | #120 | has | `Kit/Threads.swift` (`byActivity`, `activity(of:)`) | Newest loaded message, else `latest_log_id`, else creation; ties by `room_id`. The web holds the order still while the pointer is on the list; a touch list has no hover, so rows reorder as replies arrive. |
| Thread row: title, description line, latest message, unread bubble | #73, #87 | has | `Rooms/RoomListView.swift` (`RoomRow`) | |
| Inactive: quiet joined threads folded away under "Inactive · N" | #185 | has | `Kit/Threads.swift` (`ThreadList.quiet`), `Rooms/RoomListView.swift` (`FoldHeading`) | Under the open room only. Past the 5 most recently active, a joined thread quiet for 3 days (the cutoff floored to the hour) with nothing unread or mentioning you; one whose time is unknown stays up top, so a room of five or fewer never shows it. |
| Inactive starts folded, shows the open thread and any with news while folded, and stays as left | #185 | has | `Rooms/RoomListView.swift` (`inactiveThreadsOpen`) | Kept on the device, not per account, as the web's `apron.inactiveThreads`. |
| The open thread stays on the side it was on when opened, until another is | #185 | has | `Kit/Threads.swift` (`openedQuiet`, `openThreadIsQuiet`), `Rooms/RoomListView.swift` (`opened`) | The web also holds each thread's side while the pointer is on the list; a touch list has no hover. |
| Quiet threads step back (muted title) | #76 | partial | `Rooms/RoomListView.swift` | Weight changes with unread. Not verified in code: the muted look for quiet threads. |
| Other Threads heading, last active, "N more…" | #66, #74, #79 | has | `Kit/Threads.swift` (`ThreadList`, `LastActive`), `Rooms/RoomListView.swift` (`FoldHeading`) | "Other Threads · 4" folds them (kept on the device, open by default), three show, then "1 more…"; each says when it was last active ("4d", "9w", "2y"), and Join is a leading swipe or its menu. |
| Join a thread from its row | #74 | has | `Rooms/RoomListView.swift` (context menu) | |
| Leave a thread from its row without asking | #66 | partial | `Rooms/RoomListView.swift` | Leave asks first. |
| Read a thread without joining it | #102 | has | `Kit/ServerSession.swift` (`open`) | |
| Thread card in the room feed, with description and latest message | #87, #103 | has | `Timeline/TimelineView.swift` (`ThreadCard`) | |
| Thread card shows unread and private | #103 | has | `Timeline/TimelineView.swift` (`ThreadCard`) | |
| Start thread dialog: title and CommonMark Description | #71 | has | `Rooms/RoomFormSheet.swift` | A sheet; "Enter a thread title." without one; titles stop at 120 characters, as the web's field. New Room and Edit take a description too. |
| Start thread from a message, with quote as Description, first reply links back | bh | has | `Kit/Threads.swift` (`ThreadStart`, `startThread`, `thread(startedFrom:in:)`), `Kit/MessageMenu.swift` (`startsThread`), `Timeline/TimelineView.swift` | Title from the first line (60 code points), the text quoted (500, fences closed, plain text escaped). The thread opens with its composer replying to the message. A thread already started from it opens instead. A private room's other listed members are added to a thread started in it (`includeMembers(of:in:)`), from Start Thread and New Thread; refusals show in the banner. |
| Thread opens at its latest reply, pages older on scroll | #91, shazow/apron#33 | has | `Kit/ServerSession.swift` (`loadOlder`) | |
| "N+ replies" on threads with older replies | bh | has | `Kit/Threads.swift` (`replyWords`), `Timeline/TimelineView.swift` (`banner`) | The open thread's subtitle line under the bar; typing takes its place on iPhone. |
| A thread without a title is "Untitled" | bh | has | `Kit/Threads.swift` (`isUntitled`), `Kit/ServerSession.swift` (`title`) | A top-level room without one stays its `room_id`. |
| Thread header: crumb back to its room | bh | partial | `Timeline/TimelineView.swift` toolbar | Back pops the stack. No crumb with the room name. |
| Private room's thread must come back private | bh | has | `Kit/ServerSession.swift` (`createRoom`), `Kit/PrivateRooms.swift` (`PrivateRoomError.threadNotPrivate`) | Refused with the web's words and not opened. |

## 8. Room header and description

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Header title with lock for private | bh | has | `Timeline/TimelineView.swift` toolbar | |
| Pinned Description under the header, three lines, expand, × to put away | #91, #94, #117 | has | `Timeline/TimelineView.swift` (`PinnedDescription`), `Kit/HiddenDescriptions.swift` | A tap opens the rest and folds it. Put away by server and `room_id` as a fingerprint of its text (apron-web's FNV-1a), so an edit pins it again; the newest 200, in `hidden-descriptions.json`, across launches. Once put away, a room's first line is the header's subtitle (`HeaderLine.topic`). |
| Description button to pin it again | #117 | has | `Timeline/TimelineView.swift` (⋯ menu, Show Description) | In the ⋯ menu, as the bar has room for two buttons. |
| ⋯ menu: Search local history | #137, #166 | has | `Timeline/TimelineView.swift` (Search Local History), `Timeline/SearchView.swift` | A magnifying glass beside the title, where #166 moved it, and ⌘F. |
| ⋯ menu: Copy link to room or thread | #112 | has | `Timeline/TimelineView.swift`, `Kit/RoomHeader.swift` (`link(to:)`) | The web form; "Link copied" under the title for two seconds. |
| ⋯ menu: Mute and Unmute room or thread (bell-off button while muted) | #125 | has | `Rooms/MuteMenu.swift`, `Timeline/TimelineView.swift`, `Kit/ServerSession+Mutes.swift` | For 1, 2 or 8 hours or until unmuted; a thread muted with its room unmutes the room. Rows show the bell-off and stay quiet. |
| ⋯ menu: Edit room or thread (title, description) | bh | has | `Kit/RoomHeader.swift` (`editRoom`, `mayEdit`), `Rooms/RoomFormSheet.swift` | Offered with `rooms` to whoever may write, as the web; the server decides who may edit what ("Only an admin may edit the general room") and its words show in the form. Both fields go on a save, an emptied one left out, which clears it. |
| ⋯ menu: Leave, after asking | bh | has | `Timeline/TimelineView.swift` | |
| Join button in the header of an unjoined room or thread | bh | has | `Timeline/TimelineView.swift` (`Join Room`) | Inside the ⋯ menu. |
| Members toggle | bh | has | `Timeline/TimelineView.swift` (`Members`, ⇧⌘M) | |
| Untitled private room header: faces, "only you and Bob can see this room" | #124 | has | `Kit/RoomHeader.swift` (`.privateRoom`), `Kit/PrivateRooms.swift` (`privateLine`), `Timeline/TimelineView.swift` | The line is under the bar, as the other header lines. |
| Plum wash on private room headers | #124 | has | `Timeline/TimelineView.swift` (`toolbarBackground`), `Design/Apron.swift` (`privateWash`) | |

## 9. Private rooms and direct messages

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Create a room with Private | #123 | has | `Rooms/RoomFormSheet.swift` (`privateChoice`), `Kit/ServerSession.swift` (`createRoom(…isPrivate:)`) | |
| Private room that comes back public is refused | bh | has | `Kit/PrivateRooms.swift` (`PrivateRoomError.notPrivate`) | Nobody is added; the room stays joined to leave. |
| New private conversation: people picker with chips, Name for groups | #123, #129 | has | `Rooms/NewPrivateSheet.swift`, `Rooms/PeoplePickerView.swift`, `Kit/PeoplePicker.swift`, `Kit/PrivateRooms.swift` (`startPrivateRoom`) | The button says Message or Start (the chips say who), short for the bar. |
| Message on a profile card opens or starts the DM | #123 | has | `Profile/ProfileCardView.swift`, `Kit/PrivateRooms.swift` (`message(_:)`, `directRoom(with:)`) | The web skips a room whose listing is truncated (`member_count`); Ladle doesn't track `member_count` (section 10), so it trusts the members it holds. |
| "Already talking · Open" | #123 | has | `Kit/PeoplePicker.swift` (`privatePeople`), `Rooms/PeoplePickerView.swift` | |
| Private room limit "2 of 5" with Leave list (`ext.settings.private_rooms`) | #123 | has | `Kit/PrivateRooms.swift` (`privateRoomLimit`, `privateRoomQuota`, `privateRoomsQuietestFirst`), `Rooms/NewPrivateSheet.swift` (`QuotaLine`) | |
| Private room intro card at the start of history | #124 | has | `Kit/PrivateRooms.swift` (`reachesStart`, `privateIntro`), `Timeline/PrivateRoomViews.swift` (`PrivateIntroCard`) | |
| "You were added to this private room." banner with Mute, Leave | #128, #165 | has | `Kit/PrivateRooms.swift` (`ArrivalWatch`, `wasAdded`), `Kit/AddedRooms.swift`, `Timeline/PrivateRoomViews.swift` (`AddedBanner`) | #165's layout: × in the corner, Mute, Leave and Dismiss in a row under it. |
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
| Profile card: Message, Mention, Add to room | #123 | has | `Profile/ProfileCardView.swift`, `Kit/UserProfile.swift` (`addMember`, `mayMessage`), `Kit/DraftField.swift` (`mention`) | |
| Tap a mention chip, name, avatar, or member to open the profile | #149, #153, #161 | has | `Timeline/MessageRow.swift`, `Timeline/MemberList.swift`, `Timeline/TimelineView.swift`, `Kit/MessageText.swift` | A chip links `apron:?user=`; a link's `user` opens the card too. |
| Member row menu: Profile, Direct message, Remove from room | #152, #161 | has | `Timeline/MemberList.swift`, `Kit/Members.swift` (`memberMenu`) | A tap opens the card; a long press, or a secondary click on iPad, opens the menu. Your own row has none. |
| Add member (+ in the header, people picker) | #129 | has | `Timeline/AddMembersSheet.swift`, `Kit/PeoplePicker.swift` (`addablePeople`), `Kit/Members.swift` (`mayAddMembers`) | Add People in the member list's bar. A refused person stays picked with the server's words. |
| Remove from room, after a confirm | #152 | has | `Timeline/MemberList.swift` (confirmation), `Kit/Members.swift` (`removeMember`, `removeQuestion`) | "Remove Ada from general?" |
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
| CommonMark blocks: headings, lists, blockquotes, fenced code | #12 | has | `Kit/MessageBlocks.swift`, `Timeline/MessageBlocksView.swift` | Every block renders; fenced code is highlighted (next row). |
| GitHub tables and strikethrough | #12 | partial | `Kit/MessageText.swift` | Strikethrough is inline and may render. Tables do not. |
| Syntax-highlighted code blocks | #16 | has | `Kit/CodeHighlighter.swift`, `Kit/CodeGrammars.swift`, `Timeline/MessageBlocksView.swift` (`coloured`) | The web's 32 languages and its aliases, in apron.css's token colours from the active theme. A small scanner per language, not highlight.js: comments, strings, numbers, keywords, types, names after `func`/`def`/`class`, keys, and diff's headers, hunks and +/- lines. No language, an unknown one, or over 20,000 characters stays plain, as on the web (no guessing). Fewer token kinds than highlight.js (no regex literals, string interpolation or nested languages). |
| Raw HTML as text | bh | has | `Kit/MessageText.swift` | |
| Bare URL linking | #6 | has | `Kit/MessageText.swift` | |
| `@user_id` as a chip with current name | bh | has | `Kit/MessageRowModel.swift` (`MentionKey`) | |
| `#room_id` as a chip that opens the room | bh | has | `Kit/MessageText.swift` (`RoomReferenceKey`) | |
| `@&role` as a role chip that reads `@role` and opens nothing, never in code, also in reply quotes and previews | #181 | has | `Kit/MessageText.swift` (`RoleMentionKey`), `Kit/MessageText+Plain.swift`, `Timeline/MessageRow.swift` (`styled`) | Any role, known or not. Denim on denim-soft with a dotted denim rule in place of the web's 1 px ring, which a run of `Text` cannot draw. |
| A message mentions you only when `body.mentions` lists you, never for a role you hold | #181 | has | `Kit/Timeline.swift` (`mentions`), `Kit/MessageRowModel.swift` | Badges, the tint and mention counts follow the list, as the web and push do. |
| Bidi overrides dropped, text isolated in its own direction | #138 | has | `Kit/TextDirection.swift` | |
| Join and leave lines ("Ada and Bob joined · Carol left"), netted per run, 21-join baseline skipped, an add shown as a join | #170, bh | has | `Kit/MembershipLines.swift`, `Kit/ReplayStore.swift` (`membershipLog`), `Kit/Timeline.swift` (`timelineItems`), `Timeline/TimelineView.swift` (`SystemLine`) | Live and from history. VoiceOver reads every name and the time, which the web shows on hover. |
| Rename lines ("Room renamed to “Ops”", "Thread name cleared") in rooms and threads | #170 | has | `Kit/ReplayStore.swift` (`renames`), `Kit/MembershipLines.swift` (`rename`) | |
| System senders as quiet lines; `~private`, `~room`, `~server` as notice cards | bh | has | `Timeline/TimelineView.swift` (`Callout`), `Kit/MessageMenu.swift` (`NoticeMenu`) | |
| Transient notices for the session, never stored | bh | has | `Kit/ServerSession.swift` (`notices`) | |
| Welcome notice in the first room | bh | partial | `Servers/ConnectView.swift` | The welcome shows in the Connect sheet, not in the first room. |
| Copy button on a notice's code block | bh | has | `Timeline/TimelineView.swift` (`noticeActions`) | Copy each code span from the menu. |
| Show QR code for a sign-in link in a `~private` notice (fork) | fork "Show a sign-in link from a ~private notice as a QR code" | has | `Timeline/SignInQRSheet.swift`, `NoticeMenu.signInLinks` | Show QR Code under the notice and in its menu; the sheet shows the warning first, then the code. |
| Typing indicator, others' | bh, `TypingIndicator.svelte`, `RoomHeader.svelte` | has | `Kit/ServerSession+Typing.swift`, `Timeline/TypingIndicator.swift` | On iPhone a centered denim line under the navigation bar ("Ada is typing…", "2 people are typing…"), the words of the web's header subtitle under 720 px, kept out of the bar so its centered title never moves; on iPad a line with three bobbing dots above the composer ("Ada and Bram are typing…", "Several people are typing…"), its row kept so nothing moves. Reduce Motion stills and dims the dots. Held at most 300 s; a message from them or `typing: 0` ends it. |
| Send typing (`activity typing: 15`, refresh 12 s) | bh, `client.ts` `sendTyping` | has | `Kit/ServerSession+Typing.swift` (`composerChanged`) | 15 s, again no sooner than 12 s, `typing: 0` after 5 s untouched, nothing after a message. Only with `activity`; `ext:settings` does not govern typing (the web reads only `read_cursors` and `private_rooms` from it). |
| Start-of-history card for private rooms | #124 | has | `Timeline/PrivateRoomViews.swift` (`PrivateIntroCard`) | Same card as section 9's intro. |
| Placeholder while a room loads its first page | #173 | missing | `Timeline/TimelineView.swift` | No placeholder rows. |
| iOS overscroll jitter, keyboard fit | #97, #165 | N/A-iOS | | Native scrolling and keyboard avoidance. |

## 12. Message actions

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Long press opens the actions on touch | #139 | has | `Timeline/TimelineView.swift` (`contextMenu`) | Native context menu. |
| Reply | bh | has | `Timeline/TimelineView.swift` | |
| React (full picker) | #10 | has | `Timeline/ReactionPicker.swift` | Quick six, then the emoji keyboard and custom emoji. |
| Start thread | bh | has | `Kit/MessageMenu.swift` (`startsThread`) | In a room's messages, not a thread's. |
| Edit (own) | bh | has | `Kit/DraftField.swift` (edit mode) | |
| Edit keeps and edits embeds as tiles, rename uploads | #70 | missing | | Edit changes text and mentions only. |
| Select (enter select mode) | #14, #54 | has | `Timeline/TimelineView.swift` (Select) | In the message's menu, on any message in the room that isn't deleted. |
| Copy text | bh | has | `Kit/MessageMenu.swift` | |
| Copy link | #112 | has | `Kit/MessageMenu.swift` | Web form. |
| Remove reply reference | bh | missing | | |
| Delete with confirm | bh | has | `Timeline/TimelineView.swift` | |
| Move to thread or back to room | #54 | has | `Kit/MessageMenu.swift` (`moveDestinations`) | One message at a time. |
| Second tap puts the toolbar away | #118 | N/A-iOS | | The context menu dismisses natively. |
| `x` on a message selects it | bh | missing | | iPad hardware keyboard. Select mode exists; the timeline has no keyboard focus on a message for `x` to act on. |

## 13. Select mode, move, and copy

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Select mode with shift-click range | #14, #54 | has | `Kit/MessageSelection.swift`, `Timeline/TimelineView.swift` | iOS form: a check circle on each message, a tap picks or unpicks, and **Select Between** fills from the earliest picked to the latest (`spanOf`), which stands in for shift-click. `toggle(range:)` is `rangeBetween` for a hardware keyboard's range, not yet wired to a key. |
| Selection bar: count, Move to thread, New thread, Cancel | #54, #175 | has | `Timeline/SelectionBar.swift` | In the composer's place: "3 messages selected", Select Between, "1 of 3 couldn’t be moved", Cancel, Copy, and Move (Move to Room, the room's threads, New Thread…); "Moving 3…" while it goes. |
| Move all or nothing; anyone's with `move_any` | #54 | has | `Kit/ServerSession+Selection.swift` (`move`) | Someone else's message goes first, alone; refused, nothing else is sent ("No messages were moved: …"). The rest go one by one, where the web sends them at once; those refused stay picked. |
| Move to a new thread | #54 | has | `Kit/ServerSession+Selection.swift` (`moveToNewThread`), `Timeline/TimelineView.swift` | Refused before the form opens when a picked message may not move. The form suggests the earliest picked message's first line; the thread opens once its messages are in it. |
| Moved messages' authors added to the thread | #95 | has | `Kit/ServerSession+Selection.swift` (`addAuthors`) | Once each, not you, `~` identities or members; only where you may add people. "Moved, but the author couldn’t be added to the thread: …". |
| Copy the selection as a Markdown log | #164 | partial | `Kit/MessageLog.swift`, `Kit/ServerSession+Selection.swift` (`markdownLog`), `Timeline/SelectionBar.swift` (Copy) | Copy puts the log on the pasteboard and ends select mode, as the web. The web also writes an HTML rendering for rich editors (`messageLogHtml`); Ladle writes the Markdown as text only. |
| Copy quotes what a reply answers, marks cut snippets, reactions, omitted notes | #168, #172 | has | `Kit/MessageLog.swift` | Its tests are the web's with literal strings. |

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
| Rate limit: Send counts down under "Sending is paused" | #109 | has | `Kit/ServerSession+Limits.swift` (`sendWait`), `Timeline/RateLimitNotice.swift`, `Timeline/ComposerView.swift` | The ring, or a clock with × for an hour or more. |
| Uploads are paused notice (`ext:limits` upload) | #109 | has | `Kit/ServerSession+Limits.swift` (`composerWait`), `Timeline/RateLimitNotice.swift` | Holds Send only with files attached. |

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
| Preferences, Media: Server and trusted sites, or Any site; Trusted origins field | #137, #163 | has | `Servers/PreferencesView.swift` (`MediaPreferences`) | |
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
| Unread kept through a reload | #128 | has | `Kit/ReadPositions.swift`, `Kit/ServerSession+History.swift` | Positions persist, and so do the kept messages, so counts show before the connection signs in. |
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
| Muted rooms and threads don't notify | #125 | missing | | Mute exists (`mute(of:)`); waits for notifications (gap 6). |
| "Only while open" for scopes the server doesn't push | bh | missing | | |
| Alert for this server instead (one subscription) | bh | N/A-iOS | | One APNs token per device. Each server registers it. |

## 21. Search

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Search local history, as you type | #137 | has | `Kit/LocalSearch.swift`, `Kit/ServerSession+Search.swift` (`search`), `Timeline/SearchView.swift` | Kept and loaded messages (`ServerSession.kept`), 150 ms after the last key, scanned off the main actor, the newest 100. Folding, filters and snippets are apron-web's `search.ts`, offsets in UTF-16 units, its tests mirrored. Where the web's snippet marks the wrong letters after an emoji, Ladle marks the word. |
| `user:` and `room:` filters with suggestions | #137 | has | `Kit/LocalSearch.swift` (`parse`, `filterAtCaret`, `withFilterValue`, `searchPeople`), `Timeline/SearchView.swift` | People or rooms under the field with the caret in a filter's value; a tap puts in `@user_id` or `#room_id`. |
| Starts narrowed to the open room | #137 | has | `Kit/ServerSession+Search.swift` (`searchStart`) | `room:#<id> `, the caret after it. |
| Open a result where it is, paging back | #137 | has | `Timeline/SearchView.swift` (`open`), `App/RootView.swift` | As a link to the message: its room, revealed from the device then the server, and highlighted. |
| Note on how far back history is kept, linking to History | #166 | has | `Kit/ServerSession+Search.swift` (`searchNote`, `searchKept`), `Timeline/SearchView.swift` | The note under the field, and the Retention's title ("30 Days") at the bar's trailing edge, which opens Preferences > History. |
| Search rooms by name in the rooms list | | has | `Kit/ServerSession+Search.swift` (`rooms(named:)`), `Rooms/RoomListView.swift` | `.searchable` on iPhone, a field at the top of the iPad sidebar; rooms and threads by title or id, then Search Messages for the same words. |

## 22. Export and archive

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Export loaded chats as `.jsonl` (ARCHIVE.md) | #135 | has | `Kit/Archive.swift` (`text(of:)`), `Kit/ServerSession+Archive.swift` (`exportArchive`), `Servers/PreferencesView.swift` | Preferences > History > Export Chats, per server, through the share sheet; what is loaded and kept (section 2). The same lines, keys and values as apron-web's `exportArchive`, its tests mirrored; keys are in code point order, where the web writes them as received. |
| Include private rooms only when asked | #171 | has | `Kit/ServerSession+Archive.swift`, `Servers/PreferencesView.swift` | Include Private Rooms, off each visit. Left out: private rooms, their threads, their records, replies' targets in them, and anyone known only from them; "4 private rooms left out." |
| Open an export read-only (`/archive`) | #135 | has | `Kit/ArchiveServer.swift`, `Kit/ServerSession+Archive.swift` (`reading`), `Archive/ArchiveViewer.swift` | Open an Export… in History, or a `.jsonl` handed over from Files or another app (`project.yml` declares the type). A session reads it through apron-web's `ArchiveServer`, ported: guest only, read-only, rooms listed and stretches paged, replies' targets embedded. |
| Ask before loading images an export names | #135 | has | `Archive/ArchiveViewer.swift` (`askImages`) | apron-web's "Load its images?" with Open Without Images and Load Images; nothing loads from elsewhere, whatever Preferences say. |
| `ext:archive` (EXT.md §10) | EXT.md §10 | has | `Kit/ArchiveServer.swift`, `Kit/ServerSession+Archive.swift` (`archiveNote`), `Timeline/TimelineView.swift` | "An export from chat.example, saved Oct 27, 2026 at 12:00 PM. It’s read-only." in the composer's place. |

## 23. Preferences and appearance

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Preferences with Profile, Notifications, Appearance, Media, History, in the web's order | #23, #171, #177, #184 | has | `Kit/PreferencesSection.swift`, `Servers/PreferencesView.swift` | A list of the five, each a screen. Profile and Notifications are per server: for the server it was opened for, else a list of those signed in. Notifications has what Ladle notifies (Remind Me's permission) and each server's Pause; History has Retention and how much is kept (section 2); export is not built (section 22). Show Link Previews stays in the Settings app. |
| Open Preferences at a section from elsewhere (`preferencesOpener`), Back through the sections opened | #184 | has | `Servers/PreferencesView.swift` (`openPreferences`, `PreferencesRequest`), `App/RootView.swift` | The profile bar opens Profile for its server; Back goes to the list. |
| The open section in the page address (`#room=…&preferences=media`) | #184 | N/A-iOS | `Kit/PreferencesSection.swift`, `Kit/ApronLink.swift` | apron-web's own page address, not a link.apron.chat key, and no client writes it in a link. `ApronLink` refuses a link that names only `preferences` and keeps the key unread beside a place (`PreferencesSectionTests`). |
| Pause notifications in Preferences > Notifications | #184 | has | `Profile/PauseSection.swift` | Moved out of Profile, as the web's. |
| Mode: light, dark, or system, over any theme | #23, #174 | has | `Kit/Appearance.swift` (`ThemeMode`), `Servers/AppearanceView.swift`, `Design/Apron.swift` (`Appearance.setMode`) | Every window's style, sheets included. |
| Premade themes: Apron, Ferrous, Gumball, Linocut (high contrast), with previews | #174 | has | `Kit/WebTokens.swift` (generated from `THEMES`), `Kit/Themes.swift`, `Servers/AppearanceView.swift` | Read by the same parser as custom CSS; each row has a swatch in its colors and face. A theme redraws every open screen (`ActiveTheme`). |
| Base colors derive the palette (`--base-ground`, `--base-ink`, `--base-accent`, `--base-link`) | #174 | has | `Kit/ThemeCSS.swift` (`deriveTokens`) | Port of `theme-colors.ts`, held to the web's own output (`ThemeTests`, `tools/design/theme-goldens.py`). |
| Aliases follow the theme (`--focus`, the hover grounds, `--selected`, the presence colors) | #174 | has | `Kit/ResolvedTheme.swift` | `var()` read against the theme first. |
| Custom theme CSS: Apply, Discard, live preview while it reads, errors | #174 | has | `Kit/ThemeCSS.swift` (`parse`), `Kit/Appearance.swift` (`ThemeEditor`), `Servers/AppearanceView.swift` (`ThemeCSSView`) | `parseThemeCss`'s grammar, limits and messages; a theme pasted from apron-web reads the same. Tokens iOS has no use for stay in the text and are listed as not used on iOS. |
| Custom starts from the theme chosen before, the first time | #174 | has | `Kit/Appearance.swift` (`choosing`) | |
| Base colors from color pickers | | has | `Servers/AppearanceView.swift` (`BaseColorsView`), `Kit/Appearance.swift` (`ThemeBases`) | Ladle's addition: writes the same `--base-*` CSS. |
| Theme fonts: interface, messages, code (`--font-sans`, `--font-chat`, `--font-mono`) | #23, #174 | has | `Kit/ThemeFonts.swift`, `Design/Fonts.swift`, `Ladle/Fonts` | Recursive and Nunito bundled from the web's files (OFL 1.1, `tools/design/fonts.py`); first available family, scaled with Dynamic Type. Installed fonts work too. Inline code takes `--font-mono` (`EmojiText`). |
| Appearance kept per device | #174 | has | `Kit/Appearance.swift` (`AppearanceSettings`) | `appearance.json` beside `servers.json`, as the web's `apron.appearance` in this browser. |
| Fonts saved before themes become a custom theme | #174 | N/A-iOS | | Ladle never kept font fields. |
| Browser chrome (`theme-color`) takes the theme's ground | #174 | N/A-iOS | | iOS has no page chrome; the navigation bars take the theme's grounds and face. |
| Settings kept on device, applied across tabs | bh | N/A-iOS | | One app process. |

## 24. Permissions, settings, and limits

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| `ext:permissions`: write, add_members, move_any | #111, #121 | has | `Kit/Permissions.swift` | `add_members` gates Add People and Add to Room; without the extension `Permissions.core` offers adding everywhere, as the web's `CORE_PERMISSIONS`. |
| `ext:settings`: read_cursors | #111 | has | `Kit/ServerInfo.swift` | |
| `ext:settings`: private_rooms limit | #123 | has | `Kit/PrivateRooms.swift` (`ServerInfo.privateRoomLimit`) | A non-negative integer, else no limit. |
| `ext:limits` write and upload pauses | #109 | has | `Kit/RateLimits.swift` (`LimitScope`), `Kit/ServerSession+Limits.swift` | As apron-web's `limitScope` and `limitHolds`; the category counts only with the capability. |
| `retry_after` holds `history` and `message` | #109 | has | `Kit/ServerSession.swift` | |
| Reaction, join, leave refused during a pause with a toast | #109 | has | `Kit/ServerSession+Limits.swift` (`heldBack`), `Kit/RateLimits.swift` (`userFacing`), `App/ErrorText.swift` | Refused without sending; the banner gives the server's words and "Try again in 18s". |
| Only write `ext` to servers with `ext` | bh | partial | `Kit/ServerSession.swift` (`save`) | An edit resends the stored `ext` with no `ext` capability check. Ladle never writes new `ext`. |

## 25. Keyboard shortcuts

| Feature | apron-web | Status | Ladle | Note |
|---|---|---|---|---|
| Enter, Shift+Enter in the composer | bh | has | `Timeline/ComposerView.swift` | |
| Escape closes pickers, dialogs, the editor | bh | has | `Timeline/ComposerView.swift` (`.cancelAction`) | |
| ↑ ↓ Tab Enter in mention, room, emoji, command lists | bh | missing | `Timeline/ComposerView.swift` | Hardware keyboard on iPad. Touch picks work. |
| Ctrl or ⌘F opens Search local history | #137 | has | `Timeline/TimelineView.swift` | ⌘F in a room. |
| `x` selects a message | bh | missing | | Select mode exists; the timeline has no keyboard focus on a message yet (section 12). |
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

1. ~~**Code highlighting.**~~ Done (`Kit/CodeHighlighter.swift`): the web's 32 languages and aliases, unknown ones plain; inline code in the theme's mono face. Left out: highlight.js's finer tokens (regex literals, interpolation, embedded languages). Inline code takes the web's `--text-ui` size and `bg-300` ground, square, since a run of text has no padding or radius.
2. ~~**Profile card.**~~ Done (`Profile/ProfileCardView.swift`), Message included since item 10.
3. ~~**Your profile and status.**~~ Done: You (`Profile/YouView.swift`) edits the name, bio and avatar and picks a status, with the server's answer.
4. ~~**Drafts per room.**~~ Done (`Kit/Drafts.swift`): text, mentions, reply target and ready files per room and thread, kept across a relaunch.
5. ~~**Typing.**~~ Done (`Kit/ServerSession+Typing.swift`, `Timeline/TypingIndicator.swift`): sends `activity typing` as the web does, and shows others typing in the header on iPhone and above the composer on iPad.
6. **Notifications and push.** Local alerts for other rooms while open, then APNs push through a §4.9.2 relay. Add Notify me about scopes, the per-device switch, the first-mention offer, the app badge, tap to open, closing notifications once read, and a test notification. Push, never polling. L.
7. ~~**Mute and pause.**~~ Done (`Kit/ServerSession+Mutes.swift`, `Rooms/MuteMenu.swift`, Preferences > Notifications' Pause, `Profile/PauseSection.swift`). Muted rooms not notifying waits for item 6, since Ladle does not notify yet.
8. ~~**Threads.**~~ Done (`Kit/Threads.swift`, `Rooms/RoomFormSheet.swift`): Start Thread from a message, Description on New Thread, Other Threads with last active times, joined threads by activity under the open room and those with news elsewhere, "Untitled", "N+ replies". A private room's members are added to its new threads since item 10.
9. ~~**Room header.**~~ Done (`Kit/RoomHeader.swift`, `Kit/HiddenDescriptions.swift`): the pinned Description with expand and dismiss, Show Description, Edit room or thread, Copy Link in the ⋯ menu, and Copy Link and Mark as Read on a row. Search local history came with item 16.
10. ~~**Private rooms and direct messages.**~~ Done (`Kit/PrivateRooms.swift`, `Rooms/NewPrivateSheet.swift`): New Room with Private, New private conversation with a people picker, Message on the profile card, the Private section with faces, rooms named for their members, the header line and plum wash, the intro card, the "You were added" banner, the private room limit, and a private room's members added to its new threads. A room someone added you to counting unread from your join (section 19) is not built.
11. ~~**Kept view and local history.**~~ Done (`Kit/KeptHistory.swift`, `Kit/ServerSession+History.swift`, `Kit/Archive.swift`). Cache rooms and recent messages on disk so a relaunch shows them at once. Keep history with Retention, delete it on sign-out, and page older messages from the device first. L.
12. ~~**Join, leave, and rename lines.**~~ Done (`Kit/MembershipLines.swift`): netted per run, baselines of 21 joins skipped, adds as joins and renames in rooms and threads (#170).
13. **Open at the New divider.** Land on the divider instead of the latest message. Needs a device to verify the scroll. S.
14. ~~**Member management.**~~ Done (`Kit/Members.swift`, `Timeline/AddMembersSheet.swift`, `Timeline/MemberList.swift`): Add People with the people picker, Remove from Room after a confirmation, and the member menu (Profile, Direct Message, Remove) on a long press, a tap opening the card. A server that answers `unsupported` stops the offers.
15. ~~**Select mode.**~~ Done (`Kit/MessageSelection.swift`, `Kit/ServerSession+Selection.swift`, `Kit/MessageLog.swift`, `Timeline/SelectionBar.swift`), but for the HTML copy and `x`. Select several messages, move them to a thread or a new thread, add authors to the thread, and copy them as a Markdown log with quotes, cut marks, and reactions. M.
16. ~~**Search local history.**~~ Done (`Kit/LocalSearch.swift`, `Kit/ServerSession+Search.swift`, `Timeline/SearchView.swift`). As-you-type search with `user:` and `room:`, narrowed to the open room, opening results in place. Also search rooms by name. Depends on item 11. M.
17. **Message editing with embeds.** Edit shows embeds as tiles with ×. Remove an embed from a sent message (asking for uploads). Rename a file before and after sending. Remove reply reference. M.
18. **Rooms list order and folding.** Keep room order on device with drag to reorder. Fold sections to rooms with news, remember folded rooms, and fold a room's threads when it is picked again. Make Browse Rooms show member counts and descriptions, and open a room to read before joining. M.
19. **Streams and terminal output.** Read a stream's `url` live with a Live badge. Render `terminal` with ANSI colors and carriage-return overwrite. Only from the server's origin. M.
20. **Apron link chips.** Draw Apron links as chips that say what they are ("Message in #general"), and other-server links as a globe chip. S.
21. ~~**Rate limit feedback.**~~ Done (`Kit/ServerSession+Limits.swift`, `Timeline/RateLimitNotice.swift`). "Loading history is paused" by the loading row is not built: history paging waits silently.
22. ~~**Server pane.**~~ Done (`Profile/ServerPaneView.swift`). Disconnect signs out of that server, with a confirmation; a disconnect that keeps the saved session is not offered, since each server keeps its own connection.
23. **Reconnect feedback.** A floating pill with the 400/600/300 ms timing, "Checking for new messages…", the catching-up line under the header, and your own dot as a dashed ring while reconnecting. S.
24. ~~**Idle reporting.**~~ Done (`Kit/Attention.swift`, `Kit/ServerSession+Idle.swift`).
25. ~~**Sign-in QR display.**~~ Done (`Kit/MessageMenu.swift` `NoticeMenu.signInLinks`, `Timeline/SignInQRSheet.swift`): Show QR Code under a `~private` notice's sign-in link and in its menu, the warning before the code, CoreImage's generator drawn crisp. Nothing left out.
26. **Sender-side link previews.** Build `og` for GitHub, YouTube, X, Bluesky, and Wikipedia links from their public APIs, and send it as a `link` embed with × to drop it before sending. Others then see the card. M.
27. **Passkeys.** Sign in, create an account, add a passkey, and resume a held session with a tap. Needs `webcredentials` associated domains. L.
28. **External sign-in and email extras.** External sign-in through `ASWebAuthenticationSession`. Add email to an account. Handle link `state` and the "Sign in or Add it" dialog with its warning. The "add a sign-in" nudge. M.
29. **`iframe` and `html` embeds.** A paused `iframe` with Load live view in a sandboxed `WKWebView`, and sanitized `html`, with the media gate's `srcset`, `background`, and `ping` rules. L.
30. **Client-side commands.** Handle `/nick`, `/join`, `/leave`, `/topic`, `/kick`, and `/invite` locally, as the web does, and give a failed command's draft back. S.
31. ~~**Appearance.**~~ Done (`Kit/Appearance.swift`, `Kit/ResolvedTheme.swift`, `Servers/AppearanceView.swift`): mode, the premade themes, custom theme CSS and the theme fonts, as apron-web #174.
32. ~~**Export and archive.**~~ Done (`Kit/Archive.swift`, `Kit/ArchiveServer.swift`, `Kit/ServerSession+Archive.swift`, `Archive/ArchiveViewer.swift`). Export loaded chats as `.jsonl`, with Include private rooms, and open an export read-only from Files. M.
33. **Presence details.** An unknown status as a dashed placeholder with its value, the full status sort order, foldable member sections, and the `member_count` note. S.
34. **Composer details.** Standard emoji `:shortcode` autocomplete, mention chips in the field, and hardware-keyboard ↑ ↓ Tab Enter in every picker. S.
35. **Timeline polish.** The floating day while scrolling, the mention pulse on arrival, the 3-second wait for thread listings on first show, and the welcome notice in the first room. S.
36. **Keyboard shortcuts.** ⌘F for search (done with item 16), `x` to select, Alt+↑ and Alt+↓ to move a room, ← → in the image viewer, once the features behind them exist. S.
