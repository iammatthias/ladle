# Ladle UX and ergonomics specification

This document specifies how Ladle behaves on iPhone and iPad: the navigation, each screen, its states, and its gestures, keyboard, haptics, and accessibility. It covers what must hold for any visual direction. Type, color, and the bubble-or-flat question belong to the design-directions work.

Sources:

- The protocol is `PROTOCOL.md` (Apron v9) in the protocol clone. Section numbers such as §4.4 refer to it.
- Apple's Human Interface Guidelines were fetched live on 2026-10-27 from Apple's JSON endpoints. A bracketed page name such as [sheets] links to the page. The pages are listed in [HIG pages read](#hig-pages-read). Quoted HIG text is verbatim.
- The reference web client (`apron-server-go/DEVELOPMENT.md`, `.apron-web/docs/behavior.md`) is a peer that this document learns from. Ladle does not copy it.
- The code that the gap review cites is on `main`, under `Apron/` and `Packages/ApronKit/`. The `design` branch renames `Apron/` to `Ladle/` and changes nothing else in these files.

A decision that rests on no HIG page is marked **Judgment call.**

## 1. Principles

1. **Content first, chrome quiet.** The timeline and the composer own the screen. Connection state, sync, and errors appear as small indicators where they apply, never as alerts. [designing-for-ios] says "Help people concentrate on primary tasks and content by limiting the number of onscreen controls while making secondary details and actions discoverable with minimal interaction." [alerts] names Mail's connection indicator as the alternative to an informative alert.
2. **One hand by default.** Frequent controls sit in the bottom half: the composer, send, swipe to reply, room search, and Join. Rare controls go at the top. [designing-for-ios] says "it tends to be easier and more comfortable for people to reach a control when it's located in the middle or bottom area of the display".
3. **The Messages grammar first.** Long-press for actions, swipe to reply, tap a quote to jump to it, and the system emoji keyboard for any reaction. Apron-specific controls (threads, commands, origin, status) appear only where the protocol makes them necessary. [gestures] says "Avoid using a familiar gesture like tap or swipe to perform an action that's unique to your app".
4. **Show only what the client knows.** Unread counts come only from messages that Ladle holds. A dot means "something changed, count unknown". No badge stays on screen after it stops being true. [notifications] says "Keep badges up to date."
5. **Every shortcut has a plain path.** Each swipe, long-press, and keyboard shortcut has a visible control or menu item that does the same thing. [context-menus] says "Always make context menu items available in the main interface, too." [accessibility] says "Offer alternatives to gestures."

## 2. Information architecture and navigation

### 2.1 Decision

Ladle has one navigation list, **Rooms**. It has a collapsible section for each server, and each section lists that server's joined rooms. On iPad in a regular width, the list is the sidebar of a two-column `NavigationSplitView`. On iPhone, and in any compact width, the split view collapses to a `NavigationStack`: Rooms, then a room's timeline, then a thread or room info.

Threads are not sidebar rows. A room row shows how many of its threads have news. The room's **Threads** button opens the thread list, and a thread opens in the same stack as its room. This keeps the sidebar at two levels, server and room. [sidebars] says "In general, show no more than two levels of hierarchy in a sidebar."

The frequent tasks, ranked, are these:

1. Read new messages in the room you were in. State restoration lands you there (2.5).
2. Reply in that room. The composer is at the bottom.
3. Move to another room with news. This takes one back swipe, then one tap on a bold row. On iPad the sidebar is always visible.
4. Move to a room on another server. The other server's section is in the same list, with its own unread marks. It takes no mode switch.
5. Open a thread. Tap **Threads** in the room toolbar.
6. Manage a server, change your identity or status, or add a server. These are rare tasks, so they live in menus at the top.

### 2.2 Alternatives considered

| Option | Verdict | Reason |
|---|---|---|
| A server list as the root, pushing a room list (the current build) | Rejected | It puts a third level between you and a room on another server, and it hides other servers' unread state behind a tap. |
| A tab bar with one tab per server | Rejected | Server count varies, and [tab-bars] says "Avoid overflow tabs." It also says "Use a tab bar to support navigation, not to provide actions." Servers are accounts, not app sections. |
| A tab bar of sections (Rooms, Mentions, You) | Rejected for v1 | [sidebars] says "Consider using a tab bar first." Ladle has one main area, though. A Mentions tab would hold only mentions from messages the client happens to hold, because the protocol has no mention query. The tab would look empty when it is not. |
| A server switcher (pull-down title menu or bottom rail) over one server's rooms | Rejected | A switcher shows one server at a time, so unread state on other servers needs a second indicator. This is a judgment call. It scales better past about six servers, so it is the fallback if real use shows long lists. |
| One list with a section per server, in a split view that collapses to a stack | **Chosen** | It shows every server's news at once. [sidebars] says "Group hierarchy with disclosure controls if your app has a lot of content." [split-views] prefers a split view in a regular environment and a stack in a compact one. |

The layout follows the size class, not the device. [layout] says "Determine layout based on size classes, not device type or orientation." An iPad in a narrow window gets the iPhone stack. Features stay the same in both layouts. [layout] says "Don't change your app's functionality based on the space it occupies."

The root title is **Rooms**, not the app name. [toolbars] says "Don't title windows with your app name."

### 2.3 Hierarchy

```text
Rooms (sidebar / root)
├─ Server section: label, quiet status, ⋯ menu (You, Browse Rooms, New Room, Server Settings)
│   ├─ Room rows (joined, top level)
│   ├─ Thread rows promoted to top level (joined thread whose parent you have not joined)
│   └─ Browse Rooms… (last row)
└─ toolbar: Add Server (top trailing); search field (bottom on iPhone)

Detail stack
Room timeline ── Threads list ── Thread timeline
      ├── Room info (members, description, mute, leave)
      └── sheets: User profile, Reaction picker field, Delete confirmation
```

Sheets: Add Server (which includes sign-in), Sign In, Browse Rooms, New Room, New Thread, You, Server Settings, and User Profile. One sheet at a time. [sheets] says "Display only one sheet at a time from the main interface."

### 2.4 Deep links (§A.4)

Ladle cannot claim universal links for `link.apron.chat` because the owner does not control that domain. Ladle handles these links:

| Source | How it arrives | Handling |
|---|---|---|
| `apron:?…` from another app | the `apron` URL scheme in `Info.plist`, then `onOpenURL` | Parse. Ignore `token`, because servers never write `apron:` links with a token (§A.4) and any app can send one. |
| `https://link.apron.chat/#…` tapped in a message | `OpenURLAction` on message text | Handle in the app, and never open it in Safari. |
| A link pasted or scanned in Add Server or Sign In | `TokenPayload` | Use `token`, because you acted. |

The link's keys resolve as follows:

- **`server` that Ladle does not have.** Open Add Server prefilled, with the host shown. The connection waits for you to tap **Connect** (§A.4, §5.5). This applies to every link from content too.
- **`server` that Ladle has, or none (content from that server).** Select that server's section.
- **`room`.** Open the room. If you have not joined it, it opens in preview (3.5) and you join only by tapping **Join**. A link never joins or sends (§A.4).
- **`message`.** Open the room, load history around the message, scroll to it, and highlight it briefly. If it is gone, show "Message unavailable" as a toast above the composer.
- **`user`.** Open User Profile.
- **`preferences`.** Not a link key: apron-web names its open Preferences section in its own page address (#184), which no client writes in a link. A link with nothing else opens nothing; beside a place, the place opens and the key is ignored. Ladle opens Preferences at a section from its own screens (3.14).
- **`token` with `state`.** If the state is from a proposal this connection made, approve it on the server that Ladle proposed to, and ignore `server` (§4.11.2). Without matching state, ask "Sign in to chat.example with this link?" and then present it with `scheme: "token"`.

Ladle writes the `https` form when you copy or share a link (§A.4), using `ShareLink` and **Copy Link**.

### 2.5 State restoration

[launching] says "Restore the previous state when your app restarts so people can continue where they left off." For each window, Ladle restores these:

| State | Store | Restored to |
|---|---|---|
| Selected server and room or thread, and the stack path | `@SceneStorage` | The same screen |
| Scroll anchor (the `message_id` at the top edge) | `@SceneStorage` | Same position, or the New divider if new messages arrived |
| Collapsed server sections | `@AppStorage` | Same |
| Draft text, mentions, reply target, and ready files per room and thread | `drafts.json` beside `servers.json`, written on change; the files in `Staged` in Application Support, excluded from backup | Same. A reply whose message is not loaded reads "Replying to a message". An open edit is not kept, as apron-web closes its editor when the pane changes; the draft waits beside it. A file still being fitted when the app ends is not kept. |
| Rooms, users and each opened room's history within the Retention (Preferences > History) | `History/<server id>.jsonl` beside `servers.json`, in ARCHIVE.md's form; excluded from backup, file protection `completeUntilFirstUserAuthentication` | Shown at once, before the connection signs in; each room then catches up from its kept checkpoint (4.1) |
| Local read position per room | A file per server | Unread counts (4.3) |

Kept history is apron-web's history cache and kept view (#56, #137) in one file per server, for the one account signed in there, and only for an account Ladle signs back in to (a saved token), never a passing guest's. It holds what was loaded, from where each opened room's unbroken run of records starts, clamped at the Retention by `log_id` where the server's positions are times: 30 days by default; a day, a week, a year or forever; or Don't Keep, which still keeps the last day of each room, up to 150 messages, as apron-web's kept view does. A room not caught up since before the cutoff starts over from its newest page, as apron-web's `plannedRoom`. A relaunch shows each room's newest 50 entries; scrolling back pages from the device until its kept run ends, then from the server. It is written two seconds after a change and at once as the app goes to the background. Signing out, a token the server refuses, signing in as a different `user_id`, and removing the server delete it. It is left out of backups: the server holds the history, and a backup would carry a signed-out account's chats past the sign-out. Tokens never go in these files.

## 3. Screens

### 3.0 Conventions every screen follows

Each screen section below lists only where it departs from these conventions.

**States.**

| State | Rendering | Never |
|---|---|---|
| Empty | `ContentUnavailableView` with one next step as a button. [writing] says "Provide clear next steps on any blank screens." | A blank list |
| Loading the first time | Cached content, or placeholder rows (`.redacted(reason: .placeholder)`). [loading] says "Show something as soon as possible." | A full-screen spinner |
| Loading more | A small `ProgressView` row at the edge that is loading | Blocking the list |
| Offline or reconnecting | The quiet status (4.1). Content stays. | An alert, or clearing content |
| Resume refused (saved token `denied` or `invalid_params`) | The server section shows "Signed out" with the server's message and a **Sign In** button. The composer shows "Sign in to send". | Presenting the sign-in sheet unasked |
| Rate-limited (`retry_after`) | Inline beside the control: "Try again in 12 s", counting down. The control is disabled until then. A queued send waits, then retries. | An alert |
| Request error | Inline at the control, with the server's `message`, which §1.1 says is specific enough to show. Dismissible. [writing] says "display it as close to the problem as possible". | "Something went wrong" |
| Long content | Text wraps and never truncates in the timeline. Titles truncate to one line with the full text in room info. | Horizontal scrolling |

**Accessibility defaults.**

- Every row is one VoiceOver element with a composed label. [voiceover] says "Specify how elements are grouped, ordered, or linked."
- Every context-menu item and every swipe action is also an `accessibilityAction(named:)` on the same element, so VoiceOver users reach it from the Actions rotor.
- At accessibility text sizes (`dynamicTypeSize.isAccessibilitySize`), horizontally adjacent text stacks vertically. Trailing accessories (time, counts) move below the title. [typography] says "consider using a stacked layout where text appears above secondary items."
- State is never color alone. Each state has a symbol or text as well. [color] says "Avoid relying solely on color to differentiate between objects, indicate interactivity, or communicate essential information."
- Custom colors have light, dark, and Increase Contrast variants, at 4.5:1 or better for text up to 17 pt ([accessibility]). Under Increase Contrast, tints become solid strokes.
- Hit regions are at least 44 by 44 pt, even when the glyph is smaller ([buttons]). Reaction chips are never under 28 pt ([accessibility]).
- Under Reduce Motion, movement becomes a cross-fade (4.6).

**Sheets.** Cancel is at the leading edge and the confirming action at the trailing edge ([sheets]). A sheet with unsaved input asks before a swipe dismisses it ([sheets], [modality]). Esc and ⌘. cancel ([alerts]).

**Destructive actions.** These use a `confirmationDialog` (an action sheet on iPhone, a popover on iPad) whose text says what is lost, and never an alert. [action-sheets] says to use an action sheet, not an alert, "to offer choices related to an intentional action." The destructive button is never the default ([buttons]).

### 3.1 Rooms (the server list and room list)

**Purpose.** See every server's rooms and their news, and open one. Ranked tasks:

1. Open the room with news.
2. Find a room by name.
3. Mark a room read or mute it.
4. Reach server menus.
5. Add a server.

**Layout.**

- **Top.** The large title **Rooms**, and **Add Server** (`plus`) at the trailing edge. Adding a server is rare, so the top is acceptable.
- **Middle.** Sections with rows.
- **Bottom (iPhone).** The search field, through `.searchable`, which iOS places in the bottom toolbar. [search-fields] says "Place search at the bottom if there's room." On iPad, the field is at the top of the sidebar.

**Section header.** The header shows the server label and a status line only when the server is not live (4.1). An `ellipsis.circle` menu holds these items:

- **You** (`person.crop.circle`)
- **Browse Rooms** (`magnifyingglass`)
- **New Room** (`plus.bubble`)
- **Server Settings** (`gearshape`)
- **Sign In** (`person.crop.circle.badge.plus`), only while signed out

`Section(isExpanded:)` gives each section a disclosure chevron ([sidebars]).

**Room row.**

| Part | Content | Control |
|---|---|---|
| Leading | `number` for a room, `lock.fill` for a private room, `bubble.left.and.text.bubble.right` for a promoted thread | `Label` icon |
| Title | `title`, or `room_id` (§3.4). Bold when unread. | `Text`, one line |
| Second line | "Ada: last message…" when held. Otherwise the first line of `description`. For a promoted thread, "Thread in General". When threads have news, "2 threads with new replies". | `.secondary`, one line |
| Trailing | Unread count, or a dot when the count is unknown (4.3). `at` when you are mentioned. `bell.slash` before the count when muted (its own mute, or for a thread its room's), and then the news stays quiet: no bold title and a quiet count, as apron-web's RoomItem. | Count pill in the accent color, not a red badge ([notifications]: "Avoid creating a custom image or component that mimics the appearance or behavior of a badge.") |

Rooms stay in title order with `codePointLess`. They do not move by recency. **Judgment call.** A stable order keeps your memory of where a room is (Slack's default sidebar works this way), and rows never jump under your finger while new messages arrive. Unread rooms stand out by weight and the count.

**Threads under a room**, as apron-web's ThreadList (`ThreadList`). The open room (the selected one, or the room of the selected thread) lists its joined threads on a guide line, most recently active first: newest loaded message, else the server's `latest_log_id`, else the thread's creation. Then **Inactive · 2** (apron-web #185): past the five most recently active, joined threads quiet for three days (the cutoff floored to the hour) with nothing unread or mentioning you fold away under it. It starts folded and stays as you left it on this device; folded, it still shows the open thread. A thread open keeps the side it was on when you opened it until you open another, so reading it never moves its row. Then **Other Threads · 4**, the threads you have not joined, from `room_list {parent_room_id, filter: not_joined}`: a fold heading kept as you left it on this device, three rows, then "1 more…", each with when it was last active ("4d", "9w", "2y"); a tap reads one without joining, and Join is a leading swipe or its menu. Any other room lists only its joined threads with news, so nothing is missed, and the thread open in it. A thread without a title is "Untitled".

**Navigation.** Tap a row to push its timeline, or show it in the detail column on iPad. The selection stays highlighted on iPad ([split-views]: "persistently highlight the current selection").

**States.**

- No servers. "No servers yet", with the description "Ladle connects to Apron chat servers. Try the public demo server run by the Apron project, or host your own." It has **Add Server** (prominent) and a **Host Your Own Server** link to the Apron project's server, apron-chat/apron-server-go. Ladle runs no server, so these are the two places it points a new user. There is no onboarding tour ([onboarding]: "fast, fun, and optional").
- A server is signed in but has no rooms. One row, "No rooms yet", with the **Browse Rooms** row below it.
- A server is signed out. One row, **Sign In to chat.example**, plus the server's message if a resume was refused.
- Server status `stopped`. The section shows the reason and one action (4.1).
- Search with no match. "No rooms match 'ops'". The search covers joined rooms on every server, with the server label as each result's caption.

**Gestures.**

| Gesture | Action | Plain path |
|---|---|---|
| Leading swipe | **Mark as Read** (`checkmark.message`), full swipe allowed | Context menu |
| Trailing swipe | **Leave** (destructive, `rectangle.portrait.and.arrow.right`), then **Mute** (`bell.slash`, a dialog of how long) or **Unmute** (`bell`) | Context menu, the room's ⋯ menu |
| Long-press | Context menu: **Mark as Read** (through the newest loaded message, else the room's `latest_log_id`), **Copy Link**, **Mute Room** or **Mute Thread** (a submenu: For 1 hour, For 2 hours, For 8 hours, each with "until 15:42", and Until I unmute) or **Unmute** with when it ends, New Thread, Leave (last, destructive). Room Info is not built yet. | Room's ⋯ menu |

**Mute** (§4.5 `status {room_id, mute}`, capability `status`, signed in) silences a room and its threads on all your devices, as apron-web's `roomMuteChoices`: `mute` goes as the seconds left or `true`. Nothing changes until the server's `status` comes back, on every device; a refusal shows its words in the banner. A timed mute ends here at its time, and the server's `mute: false` later agrees. Unmute in a muted room's thread unmutes the room.
| Pull to refresh | None. Rooms are live over the socket. [progress-indicators] says "Don't make people responsible for initiating every update." | n/a |

Leave asks for confirmation only for a private room. You cannot rejoin a private room without an invitation, while a public room is one tap from Browse.

**Keyboard (iPad).** ⌘F focuses search. ⌥⌘↑ and ⌥⌘↓ select the previous and next room. ⇧⌥⌘↑ and ⇧⌥⌘↓ select the previous and next unread room. Return opens the selected room. These are custom shortcuts with ⌘ and no Control key ([keyboards]).

**Haptics.** None. A swipe action uses the system's own.

**Accessibility.**

- A row's label reads like "General, 3 unread, mentions you, muted". The private glyph adds "private".
- The section header is a heading (`.accessibilityAddTraits(.isHeader)`), so the Headings rotor jumps between servers.
- A custom rotor, **Unread rooms**, lists unread rows across servers ([voiceover]: "Support the VoiceOver rotor when possible.").
- At accessibility sizes, the trailing count drops below the title and the second line wraps to two lines.

**Protocol edges.**

- A joined thread whose parent you have not joined is promoted to a top-level row, with "Thread in <parent title or room_id>" (`ServerSession.roomTree` already promotes it).
- A thread without a title shows "Untitled", with its `room_id` in the room info.
- An `updated` room record renames the row in place, with no animation.
- A `left` record removes the row. If you are in that room, the timeline stays and shows "You left this room" with **Join** in the composer slot.

### 3.2 Add Server

**Purpose.** Get from nothing to signed in with as few steps as possible. Ranked tasks:

1. Scan a QR code or paste a link that has `server` and `token`.
2. Type an address.
3. Change the origin.

**Layout.** A sheet at the large detent with a `NavigationStack`, so the sign-in step is pushed inside it, not stacked as a second sheet ([sheets], [modality]: "avoid creating a modal experience that feels like an app within your app"). Cancel is at the leading edge, and **Connect** at the trailing edge.

- **Official server.** One row for the Apron project's public demo server, `wss://server.apron.chat/`, the default server of the Apron web client. Tapping it fills in the address, which sets the origin to its default, and picks Guest, the one sign-in that needs nothing else there. The row says the Apron project runs it. Under the address field, **Host Your Own Server** links to apron-chat/apron-server-go.
- **Body top.** Two paths. **Scan QR Code** (`qrcode.viewfinder`), a full-width primary button with the caption "Fills in the server and token from a sign-in code, such as the one /invite-device sends." Then a divider, "or enter manually", over the fields below. Scan QR Code is hidden when `DataScannerViewController.isSupported && isAvailable` is false, which includes a denied camera; the fields remain. The token field's `PasteButton` reads the pasteboard without the paste prompt.
- **Below them.** An **Address** field (`.keyboardType(.URL)`, `.textContentType(.URL)`, no autocapitalization or autocorrection) and a **Name** field with the host as its placeholder.
- **Advanced** (a `DisclosureGroup`, collapsed). **Origin**, with the footer "Sent as the Origin header. A token signs in only from the origin of the client that issued it, such as https://web.apron.chat."

The origin is hidden by default because the default (`https://<host>`) is right for most servers. It opens by itself when the server refuses the upgrade (4.1).

**Flow.**

1. A scanned, pasted or tapped link (`https://link.apron.chat/#server=…&token=…`, §A.4) fills in the address and the token together, and picks Token. The origin follows the address, as when you type it. A code holding only a bare token fills in only the token. Nothing connects by itself (link.apron.chat SPEC §6). The scan entry becomes a banner, "Token received. For chat.example. Check the server, then tap Connect.", with **Scan Again**. You tap **Connect**.
2. **Connect** saves the server and connects. The button shows "Connecting…" with a spinner ([buttons]: "display an activity indicator"). On the `server` frame, push Sign In.
3. If the link carried a token, Sign In opens with it filled in, and **Sign In** is the focused button. You still tap it (§A.4).

**States.**

- An address that is not a `ws` or `wss` URL. Inline: "Enter a ws:// or wss:// address." Text without a scheme gets `wss://` added.
- A server that is already saved. "chat.example is already in Ladle." with a **Show** button that selects it. Each server has one identity, so a second copy is never created.
- The upgrade is refused with 403. "chat.example refused this origin (HTTP 403)." Advanced opens with the Origin field focused.
- No answer. "Can't reach chat.example." with **Try Again**. "No internet connection" appears when the path monitor reports no route (4.1).
- `retry_after` at connect. "chat.example is busy. Trying again in 30 s."

**Keyboard.** Return in Address runs Connect when the address is valid. Esc cancels.

**Haptics.** `.sensoryFeedback(.success)` when a scan, paste or tapped link fills in a token. `.error` when Connect fails, because you are waiting on it.

**Accessibility.** The paste and scan buttons have text labels, not icons alone ([buttons]: "Consider using text when a short label communicates more clearly than an icon."). Errors are announced with `AccessibilityNotification.Announcement`.

### 3.3 Sign In

**Purpose.** Sign in with what this server offers. Each server has one identity. Ranked tasks:

1. Token, by paste or scan.
2. Email code.
3. Guest.

Passkeys and external sign-in come later (section 5.8).

**Entry points.** The second step of Add Server, the **Sign In** row or menu item, the "Signed out" banner, and the composer's "Sign in to send". It is never presented by itself on appear. The current build does that (gap 2).

**Layout.** A grouped `Form`:

1. `server.welcome`, rendered as CommonMark with raw HTML off (§3.2, §3.5.2).
2. The reason a saved token stopped working, when there is one (`signInNeeded`), with `exclamationmark.triangle`.
3. One section for each offered method that Ladle supports, in this order: token, email, guest. A method appears only if it is in `server.auth` or `server.signup` ([managing-accounts]: "Refer only to authentication methods that are available in the current context."). A scheme that is only in `signup` is labeled as creating an account, such as **Create a Guest Account**.

Each section has one action button at its bottom, within reach.

**Token section.**

- A `SecureField` labeled "Token or sign-in link". The token is a credential ([text-fields]: "Always use a secure text field when your app asks for sensitive data"). After a paste, the footer confirms what was read: "Token received" or "Link for chat.example".
- `PasteButton`, and **Scan QR Code** when `DataScannerViewController.isSupported && isAvailable`. A scanned or pasted token shows "Token received" under the field.
- **Sign In**.
- Footer: "Signed in elsewhere? In that app, send /invite-device add, or name the device, such as /invite-device add phone, then paste the token here. A server's admin can also give you one." This defines the term ([inclusion]: "Avoid using specialized or technical terms without defining them.").
- A link for a different server shows "This link is for other.example." and fills in nothing. **Judgment call:** no **Add other.example** button, since that would open a sheet from inside this one.

**Email section.**

- Step 1 is an **Email** field (`.emailAddress`) and **Send Code**.
- Step 2 is the text "Code sent to a…@example.com", a **Code** field (`.textContentType(.oneTimeCode)`, ASCII keyboard, because the code's format is server policy), **Sign In**, and **Send a New Code**. The field also accepts a pasted sign-in link (2.4).
- If the connection drops, `pendingEmail` clears and the code no longer works on a new connection (§4.11.2). Say "The connection dropped, so that code no longer works. Send a new code." Never just "Invalid code".
- A `retry_after` on Send Code counts down on the button.

**Guest section.** No name field: the server picks a guest's name (Cloudflare's demo names every guest `Guest <n>` and ignores a requested one), so the section only says so. You (3.11) says how the account signs in; the callout for a guest or token-only account to add a way back (§3.2.1's SHOULD) is not built.

**QR scanner.**

- A `fullScreenCover` holding `DataScannerViewController`, QR only, with highlighting. Add Server and Sign In open the same scanner.
- A top **Close** button, and the bottom hint "Point the camera at a sign-in QR code."
- The camera permission is requested only here, when you tap Scan ([privacy]: "Request permission only when your app clearly needs access to the data or resource.").
- Denied or restricted camera access makes the scanner unavailable, so Scan QR Code is hidden and the fields and Paste remain.
- A code that is not a token or link, such as a web address or a Wi-Fi code: "That QR code isn't an Apron sign-in." in place of the hint. Scanning continues. A sign-in closes the scanner and fills in the sheet.

The HIG has no Live Text or scanning page. The `live-text` page returned 404, so the scanner UI here is a judgment call.

**States.** While a request runs, the form is disabled and the button shows progress. A `denied` error appears under the section that sent it, with the server's message. Success dismisses the sheet and plays one `.success` haptic. The room list fills in behind it.

**Keyboard.** Return in a field runs that section's button. Fields use the matching keyboard types ([text-fields], [virtual-keyboards]).

### 3.4 Browse Rooms and Join

**Purpose.** Find and join rooms you are not in. Ranked tasks:

1. Join a known room.
2. Look inside before joining.
3. Create a room.

**Layout.** A sheet with `.medium` and `.large` detents and a grabber ([sheets]: "In an iPhone app, consider supporting the medium detent"). It has a search field, a list of `room_list {filter: "not_joined"}` results, **Done** at the trailing edge, and **New Room** in the bottom toolbar.

- **Row.** Title, then the first line of the description, then "12 members" when `member_count` or `members` is known.
- **Row trailing.** A bordered **Join** button. After joining, it becomes `checkmark` "Joined".

**Navigation.** Tap a row to dismiss the sheet and open the room in **preview**. Preview reads the room through `history` without joining, because a join is a logged membership that everyone sees. The composer slot shows a prominent **Join** button within thumb reach. Joining opens the room once its `room_update` `joined` arrives.

**States.** Loading shows placeholder rows. An empty list shows "You're in every room on this server." with **New Room**. Without the `rooms` capability, Browse does not appear (§4 fallback).

**New Room.** A sheet with **Title**, **Description**, and a **Private** toggle (a plum lock, "Only members see it, and members add others."), and **Create** at the trailing edge. A private room must come back with `private: true` in its record. If it does not, the form says "The server made “Launch” an ordinary room that others can see and join, not a private one. Leave it, or use it knowing that." and the room is not opened (§4.2.4). An `unsupported` reply says "This server doesn’t keep private rooms. Uncheck Private to create an ordinary room."

**Accessibility.** The Join button label includes the room title ("Join Deploy").

### 3.5 Room timeline

**Purpose.** Read and reply. Ranked tasks:

1. Read what is new.
2. Reply or post.
3. React.
4. Open a thread.
5. Jump to a quoted message.
6. Load older messages.

**Layout.**

- **Top.** Back, the title (one line), and a subtitle with the first line of the description or "8 members" (`navigationSubtitle`). The trailing group holds **Threads** (`bubble.left.and.text.bubble.right`, badged with the count of threads with news) and **Room Info** (`info.circle`). That is at most two items ([toolbars]: "Prioritize only the most important items"). As built: **Members** (`person.2`) and the ⋯ menu (`ellipsis`), which holds, in apron-web's order, **Copy Link to Room** (the web form; "Link copied" shows under the title for two seconds), **Show Description** once the pinned description is put away, **Mute Room** or **Mute Thread** (the row's submenu, 3.1) or **Unmute** with when it ends ("until 14:30", "until you unmute"; in a thread silenced by its room, **Unmute Room**), then **Edit Room** or **Edit Thread** (title and Markdown description, `room_set`; offered to whoever may write, the server's refusal shown in the form), then Join or Leave. Under the bar, a line says what the web's header subtitle says: who is typing (on iPhone), a thread's replies, or, once its pinned description is put away, a room's first line of description. Under that, the room's or thread's description is pinned (three lines, a tap opens the rest, × puts it away by server and room until the description changes, across launches). While muted, a `bell.slash` button left of Members says so and unmutes, as apron-web's RoomHeader; VoiceOver reads "Muted, until you unmute".
- **Middle.** Messages, oldest at top, anchored to the bottom.
- **Bottom, floating.** The status pill (4.1), centered above the composer, and **Jump to Latest** (`arrow.down`, with a count of new messages below the fold) at the trailing edge. Who is typing, as apron-web shows it: on iPhone a centered denim line under the navigation bar ("Ada is typing…", "2 people are typing…"), the web's header subtitle kept out of the bar so the centered title never moves; on iPad a line above the composer with three bobbing dots ("Ada and Bram are typing…", "Several people are typing…"), whose row stays while nobody is, when the server has `activity`. Your own typing, relayed from your other devices, never shows. Someone shows until their seconds run out (at most 300 s), their next message there, or their `typing: 0`.
- **Bottom, fixed.** The reply or edit banner, the mention suggestions, and the composer (3.7), on the keyboard layout guide ([virtual-keyboards]).

**Message row** (structure only; the look belongs to design):

- The header shows the sender name, role labels as text capsules (§3.3.4), and the time from `message_id` (§2.1). Consecutive messages from one sender within 5 minutes omit the header.
- **Name.** `Name (@user_id)` whenever another known user has the same name (§3.3.1 MUST). The muted `@user_id` also shows when there is room, which means regular width. **Judgment call** for compact width, to save the line.
- System senders. `~server` and `~room` show their names with `megaphone` and `number`. `~private` notices show "Only you", a dashed outline, and `eye.slash`, plus a close button. They are never installed as records (§3.5.3).
- Date separators ("Today", "Yesterday", "Tuesday 21 October") are headings.
- A **New** divider sits above the first unread message. The room opens at the divider when there are unread messages, otherwise at the bottom (2.5).
- When you are mentioned (`body.mentions` contains your `user_id`), the row gets a leading bar, an `at` glyph, and the label "Mentions you". It is never tint alone.

**Scrolling.**

- At the bottom, new messages scroll into view. Scrolled up, they never move what you are reading; **Jump to Latest** counts them instead.
- Sending scrolls to the bottom.
- Older pages load when the top is within one screen. A `ProgressView` row shows while a page loads.
- At the end of history, show "Start of #General". If `history_log_id` cut history short, show "Earlier messages are no longer available." Without `history`, show "Messages from before you connected aren't available on this server." (§4 fallback).

**Navigation.**

- Tap a reply quote to jump to the target. In the same room it scrolls and highlights the target for 1.5 s. In another room it opens that room first.
- Tap a sender name or avatar to open User Profile (3.10).
- Tap a `#room` chip to open the room.
- Tap an Apron link to handle it per 2.4. Other `https` links open in Safari.

**States.**

- Empty room: "No messages yet. Say hello." with the composer focused.
- Preview of a room you have not joined (3.4): the Join button replaces the composer.
- Read-only: the server refused a send with `denied`. Show the server's message under the composer.

**Gestures.**

| Gesture | Action | Plain path |
|---|---|---|
| Drag a row toward the trailing edge | Reply. The row follows your finger, with an impact haptic at the threshold. | Context menu **Reply**, VoiceOver action |
| Long-press a row | Context menu with the reaction palette (3.8) | VoiceOver actions |
| Double-tap | Nothing. **Judgment call**, because [gestures] warns against giving a familiar gesture an app-specific meaning. | n/a |
| Long-press a reaction chip | Who reacted (3.9) | VoiceOver action "Show who reacted" |
| Leading edge swipe | System back. Ladle does not override it ([gestures]: "Avoid conflicting with gestures that access system UI."). | Back button |

The reply drag mirrors in right-to-left layouts ([right-to-left]).

**Keyboard (iPad).** ↑ in an empty composer edits your last message (`edit` capability). Esc clears reply or edit mode. ⌘↓ jumps to the latest message. ⌥⌘↑ and ⌥⌘↓ change rooms as in 3.1.

**Haptics.** `UIImpactFeedbackGenerator(style: .light)` at the reply threshold. Nothing for incoming messages, mentions, or loading ([playing-haptics]: "Avoid overusing haptics.").

**Accessibility.**

- A message element reads like "Ada, 3:42 PM. Did the deploy finish? Replying to Bob: deploy is rolling. Edited. Reactions: thumbs up 2 including you."
- Custom actions: Reply, React, Copy Text, Copy Link, Start Thread, Edit, Delete, Show Who Reacted, Open Quoted Message, View Profile.
- Custom rotors: **Mentions** and **Unread**. Date separators are headings.
- New messages in the open room are announced at low priority only when VoiceOver focus is not inside the timeline. Bursts are combined ("3 new messages").
- At accessibility sizes, the time and the Edited label move below the body, and the sender stands alone on its own line.

**Protocol edges.**

| Case | Rendering |
|---|---|
| Edited (`log_id` greater than `message_id`, and no `prev_room_id`) | "Edited" after the time. VoiceOver says "Edited". |
| Moved in (`prev_room_id` set) | "Moved from #source" after the time. Not "Edited". |
| Moved out | The message leaves this timeline without a placeholder. The record re-homes (§4.4). |
| Deleted (tombstone) | "Message deleted" in secondary italics, with no reactions (§4.4) and no actions except Copy Link |
| Reply to a deleted target | The quote shows "Message deleted" |
| Reply to an unknown target | The quote shows "Message unavailable" and is not a button |
| Transient `~private` notice | Shown inline with "Only you" and a close button. It lasts for the session and is never stored. A notice without `room_id` shows in the sign-in sheet if it is open, otherwise under the server's section header. |
| Same display name | `Name (@user_id)`, from `UserDirectory` |
| Mention of someone else | `@user_id` in the text shows the user's current name in the mention style. An unknown ID renders as written (§A.3). Never inside code. |
| Unknown embed kind | Render from `og` (title, description, image) if present. Otherwise a fallback card with the kind name and `url` or `text` (§3.5.2 MUST). |
| `upload` | A pending upload (no `url`) shows a placeholder. With `og.image`, `og.video` or `og.audio`, the media where Preferences lets it load (3.14), else a Load tile. Otherwise a file card. Tap opens Quick Look ([file-management]). |
| Media from an untrusted site | A dashed tile in its place, sized from the media's aspect (120 to 200 pt tall, 320 pt wide at most): its alt text or kind, its full URL (two lines at most, cut in the middle, as apron-web #186 shows the whole URL so the viewer can judge it), and "Tap to Load". See 3.14. |
| `stream` | While live, a "Live output" card. When finished, `text` in a monospaced block that you can expand. |
| `iframe`, `html` | A fallback card with **Open in Browser** for `url`. Not rendered inline in v1 (5.8). |
| `format: "markdown"` | CommonMark with GitHub tables and strikethrough, as apron-web's markdown-it (`html: false`, `breaks: true`): headings, paragraphs, quotes with a rule at their edge, ordered and bulleted lists, code blocks, rules, and tables. Raw HTML shows as text. A typed line break is kept. Code blocks and tables scroll sideways inside the message, so a wide one never widens the row. Text follows Dynamic Type. Links, mentions, room chips and custom emoji are never drawn inside code. Each image (`![alt](url)`) is a block of its own under the media gate (3.14): the image at its shape, a Load tile naming its alt text and host, or, on a scheme that cannot load, its alt text. A linked image shows as its link. The same rendering covers notices, the server description and the welcome. Room and thread descriptions in rows read as one line per block. |
| `format: "plain"` | The text as written, one paragraph, with bare links, mentions and custom emoji |
| Membership records | Join and leave lines, as apron-web's (#170): consecutive records with nothing else between them (a day pill counts) make one quiet centered line, netted per user ("Ada and Bob joined · Carol left"; past three names, "Ada, Bob, and 4 others"). Someone who joins and leaves within a run, as a guest passing through, is in neither list, so churn stays quiet. A record of 21 joins or more is the baseline a server logs before it drops history, not news, and gets no line. An add by someone else is a join. VoiceOver reads every name and the time. |
| A room record with a new `title` | "Room renamed to “Ops”" or "Thread renamed to “Deploy”" at its `log_id`, or "… name cleared". A description edit makes no line. |

### 3.6 Thread

A thread is a room with `parent_room_id`, so it uses 3.5 with these differences.

**Threads list.** As built, threads list in the rooms list under their room, as apron-web's sidebar (3.1, "Threads under a room"), not on a pushed screen: joined ones by activity, Inactive, then Other Threads with when each was last active. A row shows the title, the description line, its latest message and an unread count. New Thread is in the room row's menu. Swipe actions: Leave on joined threads, Join on others.

**Thread timeline.** The title is the thread title, and the subtitle is "in #General". Tap the subtitle to go to the parent room.

- In a thread you have not joined, the composer placeholder reads "Reply (joins the thread)". Sending joins first, then posts. A poster who has not joined gets no broadcast (§4.2.2).
- The subtitle line under the bar says how many replies are loaded: "1 reply", "12 replies", or "12+ replies" while older ones are still to load. On iPhone, who is typing takes its place.
- **Start Thread** from a room's message (3.8) opens the thread form (`RoomFormSheet`, also New Thread and New Room): the title from the message's first line that is not blank, its white space made single, at most 60 code points; the description the message quoted as Markdown (`> `), cut near 500 code points on a line or word with a code fence closed, plain text escaped. Ladle creates the thread with `room_set` (`parent_room_id`, `title`, `description`; never `private`, which a thread takes from its room). It opens with its composer replying to the message: that first reply is the link back, the web client's convention. Start Thread on a message that already has a thread (one this device started, or one loaded from its start whose first message replies to it) opens that thread.

**Keyboard.** ⌘[ goes back to the parent. This is system navigation.

### 3.7 Composer

**Purpose.** Write a message, reply, edit, command, or mention.

**Controls.**

| Part | Component | Notes |
|---|---|---|
| Text | `TextField(axis: .vertical)`, 1 to 8 lines, then scrolls | Placeholder "Message #General". In a thread, "Reply in Deploy". |
| Send | `Button` with `arrow.up.circle.fill`, 44 pt hit region, the only prominent control ([buttons]: "Keep the number of prominent buttons to one or two per view.") | Disabled when the text is empty |
| Reply or edit banner | Above the field. `arrowshape.turn.up.left` "Replying to Ada: first line…" or `pencil` "Editing", with `xmark.circle.fill` to cancel | Tap the banner to scroll to the target |
| Command tag | `terminal` "Command" at the leading edge, when the text starts with one `/` and the server has `command` | The send button's label becomes "Run". `//` sends a message that starts with `/` (§4.1). |
| Mention suggestions | A list of up to 8 rows above the field after `@` | Room members, then roles others here hold (a group glyph, `@role`, "2 people"), roles keeping 3 rows when people fill it. `@&` lists roles alone. |
| Status line | "Sign in to send" with a **Sign In** button, or "You left this room" with **Join** | Replaces the field. The field is never just disabled without a reason. |

**Behavior.**

- Picking a suggestion inserts `@user_id ` and adds the user to `body.mentions` (§3.5.5). A typed `@user_id` that names exactly one known member counts too. Text alone never mentions anyone. Picking a role inserts `@&role `, as sent (apron-web #181): when the message goes, everyone else in the room who holds the role then is listed in `body.mentions`, where the text names it, after anyone named before it. A message mentions you only when its `body.mentions` lists you; holding the role is not enough. In rendered text `@&role` is a chip that reads `@role` and opens nothing. **Judgment call.** Ladle inserts the literal `@user_id` that is sent, rather than a name chip, because a plain `TextField` cannot hold chips. The sent text is then exactly what you see.
- Commands send everything after `/` as a `command` request. Replies arrive as `~private` notices in the timeline (3.5). A failed command shows its error in the same style. Ladle handles no command locally in v1. **Judgment call**, because §4.1 makes local handling optional.
- An edit sends again every client field it keeps (`ServerSession.edit` already does this, §4.4). Edit is offered only for your own messages on `edit` servers.
- Each room and thread keeps its own draft: the text, its mentions, the reply target and the staged files, as apron-web's `PaneDrafts` does, and across a relaunch (2.5), where apron-web instead warns that reloading clears an unsent message. Switching rooms never loses text. Reply keeps the text and files; canceling a reply keeps the text. An edit opens beside the draft and gives it back on save or cancel. A file dropped or picked while you leave the room lands in that room's draft once it is fitted. Sending empties the room's draft. Removing a server removes its drafts and their files; files no draft holds are swept at launch.
- Typing (the `activity` capability) sends `typing: 15` at most once every 12 s while you type in the composer, never the editor, and `typing: 0` once it has been left alone for 5 s, as apron-web's `composerInput` and `sendTyping`. Sending a message sends no `typing: 0` (§4.6: the message ends it). `ext:settings` has no say in typing.

**Return key.** The on-screen keyboard's Return inserts a new line, as in Messages, and Send is the button. On a hardware keyboard, Return sends, ⇧Return and ⌥Return insert a new line, and ⌘Return always sends. **Judgment call** that follows Messages on iPad. The HIG has no guidance on multi-line composers.

**Sending, failure, and the outbox.** See 4.2. A sent message appears at once as pending and is never shown twice. The draft clears only into the outbox, never into nothing.

**Waits the server asks for** (§1.1 `retry_after`, `ext:limits`), as apron-web's RateLimitNotice and `heldBack`. A refused request notes what it holds back: a refused `message` holds back sending; with `ext:limits`, a `write` refusal holds back posting, reactions, joins, leaves and room changes, and an `upload` refusal holds back only messages (and commands) with new files. While a wait lasts:

- Above the composer, "Sending is paused. You can send again in 17s." and "Uploads are paused. Uploads resume in 2h 5m.", counting down each second (`17s`, then `m:ss`; a wait of an hour or more in `3h 12m`). A ring in the warning color empties as the wait runs out; a wait of an hour or more shows `clock` instead and has × to put it away, and the next Send shows it again. VoiceOver hears the wait once, as it began ("You can send again in 17 seconds").
- Send shows `hourglass` and the time left, and does nothing; the draft and its files stay, and nothing goes by itself. An upload wait holds Send only while files are attached. A message already in the outbox waits out the time and goes, as before (4.2).
- A reaction, join or leave during a write wait is refused without sending, in the server's words with when to try again: "Posting limit reached. Try again in 18s." Every refused request with `retry_after` reads that way.
- A wait belongs to its account: another sign-in starts without them.

**Accessibility.** Suggestions are announced as "3 suggestions", and each is a button. The field's accessibility label includes the room ("Message, General"). The send button label is "Send" or "Run".

**Haptics.** None on send. `UINotificationFeedbackGenerator` `.error` once when a send fails while the room is on screen.

### 3.8 Message actions

**Context menu** (long-press, or secondary click on iPad). The preview is the message itself ([context-menus]: "Prefer a graphical preview that clarifies the target of a context menu's commands.").

1. A reaction palette row: 👍 ❤️ 😂 🎉 👀 🙏 and **More** (`face.smiling`). Use `ControlGroup` with `.controlGroupStyle(.palette)`. Reactions require the `reactions` capability.
2. **Reply** (`arrowshape.turn.up.left`).
3. **Start Thread** (`bubble.left.and.text.bubble.right`). Requires `rooms`. Not shown inside a thread.
4. **Copy Text** (`doc.on.doc`) and **Copy Link** (`link`).
5. **Select Text** (`selection.pin.in.out`). It opens a sheet with the message as selectable text. [context-menus] says "Provide either a context menu or an edit menu for an item, but not both."
6. For someone else's message: **View Profile** and **Mention**.
7. For your own message on `edit` servers: **Edit** (`pencil`), then **Delete…** (`trash`, destructive, last). [context-menus] says to list destructive items "at the end of the menu and identify them as destructive".

Items that do not apply are hidden, not dimmed ([context-menus]: "Hide unavailable menu items, don't dim them.").

| Message state | Menu |
|---|---|
| Tombstone | Copy Link only |
| `~private` notice | Copy Text, Dismiss |
| Your pending message | Cancel Sending |
| Your failed message | Retry, Edit, Delete (local only, no confirmation) |

**Delete.** A `confirmationDialog`: "Delete this message for everyone? This can't be undone." It has **Delete** (destructive) and Cancel. The protocol has no undo, so [alerts]'s "Avoid displaying alerts for common, undoable actions" does not apply.

**Offline.** Reply works and queues (4.2). React, Edit, Delete, and Start Thread are hidden while offline. A banner at the top of the menu, "Offline. Reactions and edits are available when connected.", says why. **Judgment call**, because they are hidden, not dimmed, so the reason must be stated.

### 3.9 Reaction picker and chips

**Palette.** Six emoji in the context menu (3.8). This is the Messages tapback model.

**More.** It presents a compact sheet with one field that asks for the emoji keyboard (a `UITextField` subclass whose `textInputMode` returns the active mode with `primaryLanguage == "emoji"`). The first emoji you type is applied, and the sheet closes. If you have no emoji keyboard enabled, the field shows the normal keyboard with "Switch to the emoji keyboard with the globe key." A browsable picker is deferred (5.8). **Judgment call** that follows Messages, which opens the emoji keyboard for a custom tapback.

**Chips.** The chips wrap under the message in a flow layout and never scroll sideways. Each chip shows the emoji and the count. Your own reaction is shown as a filled chip with an outline, not a tint alone. Tap toggles yours: Ladle sends your complete set (`toggleReaction`, §4.7). Long-press shows **Reacted with 👍**, a list of names (a popover on iPad, a `.medium` sheet on iPhone).

**States.** A pending chip updates at once and settles when the `reactions` broadcast arrives. If the request fails, the chip reverts, and the server's message shows below the message for 4 s and in the VoiceOver announcement. A server limit shows the server's message, for example "Up to 20 reactions per message". Tombstones show no chips.

**Haptics.** `UISelectionFeedbackGenerator` on each toggle.

**Accessibility.** A chip reads "Thumbs up, 3, including you". Its action is "Add reaction" or "Remove reaction". Chips have 44 pt hit regions with spacing between them ([accessibility]: "Consider spacing between controls as important as size.").

### 3.10 User profile and presence

**Purpose.** See who someone is, and mention them or add them to the room, as apron-web's ProfileCard. **Entry.** A sender's avatar or name in the timeline, a mention chip, a member row, a link's `user`, or VoiceOver's "Ada's Profile" action on a message. **Layout.** A sheet at `.medium` height that can grow to `.large` (`ProfileCardView`), on iPhone and iPad alike; from the member list it opens over the list.

- **Top.** Avatar with its status dot, or initials where no avatar may load (§4.8.6). Beside it the name and "(you)", then `@user_id` (selectable) with a copy button, the status in words, "Last seen 3h ago" while they show offline, and roles as badges.
- **Same name.** When another user shows with the same name: "Another user also shows as **Ada**. Check the @user_id." (§3.3.1).
- **Bio** (`ext:bio`), selectable, in its own direction.
- **Membership.** "Member of general" or "Not in general", once the room's members are known.
- **Actions.** **Mention** (prominent: puts `@Name ` at the end of the composer and closes the card; also closes the member sheet on iPhone) where the composer takes text and the user is not a `~` system identity, and **Add to Room** (`room_join` with `user_id`, §4.2.2) where you may add them: `add_members` (or a server without `ext:permissions`, where PROTOCOL.md lets any member ask, as apron-web's `CORE_PERMISSIONS`) or a private room you are in, the members known and they not among them. A line under the actions says "Copied @ada", "Added to ops", or the server's refusal.
- **Message** (prominent, before Mention, which then takes the ghost style) for anyone but you and the `~` identities, on an account (not a guest) that may write, with `rooms`: it opens the private conversation you already have with them, or starts one (3.16), and closes the card. One started that couldn't add them stays under Private, and the card says "Couldn’t add Ada: …. The room is kept under Private."

| Shown status | Dot | Text |
|---|---|---|
| `online` | disc | Online |
| `idle` | crescent | Idle |
| `dnd` | disc with a bar | Do not disturb |
| `offline` | ring | Offline, plus "Last seen 3h ago" from `seen` (§4.5.2) |
| your own `invisible` | ring | Invisible · others see you as offline |
| `""`, or absent | none | No status line |
| An unknown value | dashed ring | "Unknown status: away-ish" (§4.5.2: shown as unknown, with the value) |

Last seen reads "recently" under ten minutes (a server may record `seen` coarsely), then minutes, hours or days up to two weeks, then the day ("Last seen Sep 14", with the year when it is not this one), as apron-web's `lastSeen`.

**Member list.** As apron-web's MemberList (#129, #152, #153, #161): a tap on a member opens their card; a long press (or secondary click on iPad) opens their menu, **Profile**, **Direct Message** (as the card's Message) and **Remove from Room** (in the danger color), and your own row has no menu. Remove asks "Remove Ada from general?" first and sends `room_leave` with their `user_id`. **Add People** (`person.badge.plus`) in the list's bar opens a sheet like New private conversation's picker, "Add People to general", of those known who aren't members, or the `@user_id` typed whole ("Add by @user_id: @carol"; a display name is never looked up, since names aren't unique). **Add** adds each in turn; one refused stays picked with the server's words, and the sheet closes once all are in. Adding and removing are offered while signed in with `rooms`, allowed to write and in the room; adding also needs `add_members` (as above) or a private room. Who may is the server's to say, and its refusal shows under the list. A server that answers `unsupported` stops the offers, and the list says "This server doesn’t let members add or remove others."

**Room info.** Not built yet (PARITY gap 9). It is pushed from the room toolbar.

- The title and description (CommonMark), with **Edit** (title and description, `room_set`, resubmitting the other client fields) when you are a member.
- **Mute** as a `Toggle` row (§4.5.3 with `room_id`). Its footer reads "Mutes notifications for this room and its threads on all your devices."
- **Members**, with status, sorted online, idle, dnd, unknown, offline, then no status.
- **Copy Link**, then **Leave** at the end.

### 3.11 You (profile and status)

**Purpose.** Change how this server's account appears, as apron-web's Preferences > Profile. Each server has its own. **Entry.** The profile bar at the foot of the room list (your face, your name, a gear, and under the name "Paused until 14:30" with `bell.slash` in the warning color while your notifications are paused, else your status in words, else your `@user_id`; the gear then carries a small bell-off, and VoiceOver hears "Notifications paused until 14:30"), which opens Preferences at Profile for this server (3.14), or Edit Profile in the server pane (3.12), a sheet of its own. **Layout.** A grouped `Form` (`YouView`). As a sheet, **Done** closes it; **Save** is on while the name or bio differs from what the server keeps.

| Section | Rows | Protocol |
|---|---|---|
| Display Name | Your avatar with **Upload Avatar** or **Change Avatar** (where `/avatar` takes an upload) and **Remove Avatar** (when you have one), the **Display name** field, which saves on Return, and **Revert** while it differs. The footer reads "User ID assigned by server: @ada", selectable. | `/avatar` with an upload embed (§4.8.6); `me {avatar: ""}`; `me {name}` (§3.3.2). The result's `you` is complete and replaces what is kept. |
| Bio (`ext:bio` or `ext`) | A multi-line field, "A few words about you, in plain text", with a count to 250 in the header that turns red over the limit | `me {ext: {bio}}`, cleaned as apron-web's `cleanBio`; `""` clears it. Sent before the name. |
| Status (`status`, signed in) | A menu picker, **Show Me As**, each choice with its dot and hint: **Online** (Automatic) and **None** (Show no status) always, **Do not disturb** (Mutes notifications) and **Invisible** (Appear offline) only where `server.status` lists them (§4.5.1). The footer says what the current one means to others. | `me {status}`. |
| Pause Notifications (`status`, signed in; in Preferences > Notifications, as apron-web #184, not here) | **Pause…**, a menu of For 1 hour ("until 15:30"), For 8 hours, Until tomorrow ("9:00", or Until this morning before 9:00) and Until I resume, as apron-web's `pauseChoices`. While paused, "Paused until 22:30 · no notifications on your devices." in the warning color, and **Resume**. The footer, when not paused: "Silence notifications on all your devices for a while. Only you see it." A refusal shows a callout, "Notifications weren’t paused" or "Notifications are still paused", with the server's words. | `status {mute}` without `room_id` (§4.5): seconds left, `true`, or `false` to resume. The line changes when the server's `status` says so, on every device, set here or elsewhere. |
| Sign-in | How this account signs in, and **Sign Out** (3.12's confirmation). The footer reads "Signed in to Home as Ada." | |

What the server did with a save shows under the name: "Saved." for two seconds, "The server saved your name as “Ada L.”" when it kept another, or "The server declined this name (…). Your old one is still in use." in red. A bio the server refuses as `too_large` says "Your bio is too long for this server. Try a shorter one." and the name is not sent.

When the server keeps another status than the one chosen, a callout under the picker says so: "This server doesn’t offer Do not disturb. Your status is None." for an optional one, which the picker then stops offering on this server, or "The server chose another status." A refusal, such as `retry_after`, reads "Your status didn’t change. The server declined Invisible (…)." and nothing changes (§4.5.3). VoiceOver announces the callout. Your chosen status comes only from `you` (§4.5.2); your own Invisible reads "Invisible · others see you as offline".

Not built yet: Add Email and the other ways to add a sign-in (gap 28).

### 3.12 Server pane

**Purpose.** Which server this is, how the connection stands, who you are there, and the way to another server or out of this one, as apron-web's ServerPane (#177). **Entry.** The room list's title, "Home ⌄", on iPhone; on iPad the head above the rooms (the server's tile, name and host), as the web's sidebar head. **Layout.** A sheet at `.medium` height (`ServerPaneView`).

1. **Head.** The server's avatar, or its initials on a tile, its name (3.1's `serverName`), then a dot and the connection in words with the host: green "Connected", amber "Connecting…" or "Reconnecting…", red "Not connected" or what stopped it (4.1's words).
2. **Description.** The server's `description` as CommonMark, with custom emoji.
3. **You.** "Signed in as Ada", with "(guest)" for a guest, and **Edit Profile**, which opens You (3.11).
4. **Address.** The WebSocket address, selectable, with a copy button that turns to a check for a moment, and the protocol version, "Apron 9".
5. **Actions.** **Connect to Another Server…** opens the Connect sheet (3.2) for a new server. **Disconnect** signs out of this server only: Ladle keeps several servers side by side, so the web's Disconnect, which leaves its one server for the connect screen, maps to signing out here. The others stay connected.

**Sign Out confirmation**, from Disconnect and from You's Sign Out: "Sign out of Home?" with "This account signs in only with its token, which is deleted. You may not get back into it." for a token or guest account, and "You can sign in again with the same method." otherwise. The Keychain item is `ThisDeviceOnly`, and Ladle never shows the token, so for token-only accounts the loss is real.

The server's name, address and origin are edited in the Connect sheet (Edit on the server list), and **Remove Server** stays on the server list's swipe and menu, with its confirmation: "Ladle forgets this server and its sign-in. …". The `agent`, capabilities and schemes are not shown.

### 3.13 Connection and error states

Connection state is not a screen. It is one model, rendered in the Rooms section header and in the timeline status pill. Section 4.1 defines it.

### 3.14 Preferences, and media from other sites

**Purpose.** apron-web's Preferences (#184): Profile, Notifications, Appearance, Media and History, in its order. The Media section chooses where images, video, audio, avatars and custom emoji load from. Loading one tells the site that hosts it that you are reading (§5.5).

**Entry.** **Preferences** (`gearshape`) at the leading edge of the Servers toolbar on iPhone, and at the foot of the server rail on iPad, opens it at its list. The profile bar's gear opens it at Profile for that server, as apron-web's `preferencesOpener`. It is one sheet with **Done** and a navigation stack: a section opened directly sits over the list, so Back goes to the list, as apron-web's Back steps through the sections opened. apron-web also names the open section in its page address; that is not a link.apron.chat key, so a link naming only `preferences` opens nothing (2.4).

**Sections.**

- **Profile.** You (3.11) for the server it was opened for; opened from the server list, the servers you are signed in to, each opening its You.
- **Notifications.** Whether iOS lets Ladle notify (On, Off in Settings with **Open Settings**, or asked with your first reminder): Ladle notifies for Remind Me; alerts for messages need push (§4.9), not built. Then **Pause Notifications** for each server with `status` (3.11's former section, as apron-web's PauseNotifications), headed with the server's name when several show.
- **Appearance.** 3.15.
- **Media.** Below.
- **History.** **Retention**, apron-web's six choices in its words (Don't keep, A day, A week, 30 days, A year, Forever; 30 days by default), for every server, with "Signing out deletes stored history." Under it, "Using about 12 MB." (every server's kept history as last written), or in red why keeping stopped ("There isn't enough space on this device to keep more history."). A new choice rewrites what each server keeps at once (2.5). Export Chats and Open an Export read "Not yet" (PARITY section 22).

**Media layout.**

1. **Load Media From.** An inline picker: **This Server and Trusted Sites** (the default) or **Any Site**. The footer says what each does.
2. **Trusted Sites.** Your sites, one row each, swipe to delete. A field takes a site as a bare host (`cdn.example`) or any URL on it, several at once separated by spaces or commas. Only `https:` with a dotted host is kept, reduced to its origin and listed once, as apron-web's `parseMediaOrigins`. Anything else shows "Enter an https site or address…" under the field.
3. **Trusted by Your Servers.** Read-only. Each signed-in server's own origin and the origins its `ext:media` names.

**Scope.** Your trusted sites are global: they are sites you trust, so they apply on every server. A server's own origins apply on that server only. The choice is kept in `media-settings.json` beside `servers.json`. Under **Any Site**, the list stays for when you switch back.

**Rules** (one decision point, `MediaGate.decide(url, for:)`):

| Media | This Server and Trusted Sites | Any Site |
|---|---|---|
| Inline `data:` image | Shows | Shows |
| Server's origin, its `ext:media` origins | Shows | Shows |
| A trusted site | Shows | Shows |
| Timeline media elsewhere (uploads, link card images, video and audio, markdown images) | Load tile | Shows |
| Avatar or custom emoji elsewhere | Initials, or the key as text. The emoji picker leaves it out. | Shows over `https:` only |
| Custom emoji catalog elsewhere | Not fetched | Fetched over `https:` |

**Load tile.** A tap is **Load**: that one URL loads, until Ladle quits. The tile's `ellipsis.circle` menu and its long press offer **Load** and, for an `https:` site, **Always Load from host**, which adds the site to Trusted Sites. A link card whose `og.video` waits shows a Video tile under the card even when its image loads, so the video is never silently dropped. A loaded image that fails (an unreachable host, a bad file) shows the `photo` glyph in its box and never spins.

**Accessibility.** The tile reads its kind and its full URL, "Image, https://shazow.net/images/icon.png, not loaded", with the hint "Loads it". **Always Load from host** is a custom action.

### 3.15 Appearance

**Purpose.** Choose light, dark or the system's, and a theme, as apron-web's Preferences > Appearance (#174). Per device, like the web's: kept in `appearance.json` beside `servers.json`, sent nowhere.

**Entry.** Preferences > **Appearance** (3.14).

**Layout** (`AppearanceView`).

1. **Mode.** A segmented control: **System** (the default), **Light**, **Dark**. It sets every window's style, sheets included, whatever the theme.
2. **Theme.** Apron (the default), Ferrous, Gumball, Linocut (high contrast), and Custom, one row each with a swatch in that theme's own ground, ink, accent, link and face, and a checkmark on the one chosen. A theme applies at once, to every screen already open. The footer says what a theme sets, that Custom starts from the theme you had, and credits the fonts (Recursive for Ferrous, Nunito for Gumball, OFL 1.1).
3. With Custom chosen, **Theme CSS** opens the CSS (`ThemeCSSView`): the same text as apron-web's Theme CSS field, in a monospaced editor of at most 4000 characters. A theme pasted from apron-web reads the same here: the same grammar, limits and messages (`ThemeCSS.parse`). An edit shows on every screen while it reads; while it doesn't, the last one that did stays on show and "Not showing yet: …" says why. **Apply** (the toolbar) keeps it; a refused Apply shows the error in the danger color and VoiceOver announces it. **Discard Changes** goes back to what is kept, and so does closing Preferences. Under the editor, "Kept, but not used on iOS: …" lists what the theme sets that Ladle has no use for (`--z-*`, `--font-emoji`, apron-web's `--pref-` widths, names tokens.css lacks) or can't read; they stay in the text. **Colors…** opens **Base Colors**: Ground, Ink, Accent and Link, each with a Light and a Dark color picker, starting from what shows. **Done** writes them into the CSS as `--base-*` declarations (`light-dark(light, dark)`, or one hex where the modes agree), replacing any there outside comments, and the palette derives from them as on the web.

**What a theme can set on iOS.** Any token Ladle reads from tokens.css: every color (any CSS color syntax people write by hand: hex, `rgb()`, `hsl()`, `oklch()`, `oklab()`, named colors, `light-dark()`, `color-mix(in srgb, …)`, `var()`), the four base colors, the three faces (`--font-sans` for the interface, `--font-chat` for message text, `--font-mono` for code; a family the device lacks is skipped, as in the browser), text sizes and line heights (at the Large Dynamic Type setting, scaled from there), spacing, radii, avatar and control sizes, durations, the slide easing, opacities, the count shade and shadows. An alias follows what the theme sets: `--focus` is its accent, the hover grounds its grounds, `--selected` its ink at 8%.

**Increase Contrast** still swaps the theme's `line` for its `line-strong` and its `ink-muted` for its `ink`.

### 3.16 Private rooms and direct messages

**Purpose.** Talk with chosen people where no one else can read, as apron-web's private rooms (#123, #124, #128, #129, #165). Everything goes by a record's `private: true` and `parent_room_id`, never a `room_id` (§2.4, §4.2.4).

- **Private section.** The rooms list keeps the joined top-level private rooms in a **Private** section under Rooms, each row led by its faces (one person's avatar with their dot, or two of a group overlapped, as the web's Faces) in place of the lock; their threads sit under them as in Rooms. The section shows while it has rooms, or empty for its **+** where you may start one.
- **Names.** An untitled top-level private room is named for its other members, by name, sorted ignoring case and accents, joined with ", " ("Bram, Chiara"), "You" when no one else is in it, and "Private room" while its members are unknown. Rows, the header, the composer's placeholder and pickers all read the one title.
- **New private conversation.** The **+** beside Private (an account, not a guest, that may write, with `rooms`) opens a sheet: **To**, the people picked as plum chips with ×, a field narrowing everyone the session knows (but you and `~` identities) by name or `@user_id`, 50 at a time, a picked row with a check. While no one is picked, someone you already talk to (an untitled private room of just the two of you) reads "Already talking · Open" and opens it. Two or more picked offer **Name** (optional, 120 characters). **Message** (one) or **Start** (more) sends `room_set {private: true, title?}` and, once the record says it is private, `room_join` with each `user_id` in turn; one refused doesn't stop the rest, and the room opens with "Couldn’t add Carol: …" over the list. Picking only someone you already talk to opens that room instead.
- **The limit.** With `ext.settings.private_rooms` (`ext:settings`), the sheet's foot says "4 of 5" with a pip per room (up to ten). At the limit the people give way to "You’re in 5 private rooms, the most this server allows at once. Leave one to start another." and your private rooms, quietest first ("Last active 3d ago"), five of them and "and N more", each with **Leave**; nothing can start.
- **Header.** An untitled private room's title leads with its faces and a plum lock, and the line under the bar says "Online · only you and Ada can see this room" (one other, with their status), "Only you and Ada can see this room", "Only members can see this room" or "Only you can see this room". A private room's bar takes the plum wash (the web's `private-soft` at 60% over `bg-100`).
- **Intro card.** Once a top-level private room's loaded history reaches back to its creation (nothing older to load, and the retention floor at or before its first record seen), the timeline opens with a plum card: its faces, its name, one person's `@user_id` and the first line of their bio (or "3 members"), and "Private room. Only members and the server host can read messages here. Only members can add others."
- **You were added.** A top-level private room that arrives joined without this device asking (not one it created or joined; the first listing for an account is the baseline, and later listings count, so one added while away shows) gets "You were added to this private room." under the header, with × in its corner and **Mute** (or **Unmute**), **Leave** (asking first) and **Dismiss** in a row under it, on a plum wash. Each is kept on the device (`added-rooms.json`) until dismissed. A room joined on another of your devices arrives the same way, as membership records don't say who made a change (§4.2.2).
- **Threads.** A thread started in a private room (New Thread or Start Thread) must come back private: one that doesn't says "The server made the new thread visible to people outside this private room, so nothing was posted into it." and isn't opened. Once it opens, the room's other listed members are added to it (`room_join` with each `user_id`), so they see it and its replies; refusals show in the room's banner.

## 4. Cross-cutting

### 4.1 Connection and sync, as you see them

The session is live by default. The UI says something only when it is not live, and never with an alert. [alerts] says to prefer "an alternative way to communicate it within the relevant context", and [feedback] says "Consider integrating status feedback into your interface."

| `ServerSession.Status` (plus the path monitor) | Section header line | Timeline pill | Composer | Action |
|---|---|---|---|---|
| `connecting`, first launch, cached view shown | "Connecting…" | "Connecting…" | Queues (4.2) | none |
| `signedIn`, catching up after a reconnect or launch | none | "Checking for new messages…" | Sends | none |
| `reconnecting`, attempts 1 to 3 | none | "Reconnecting…" | Queues | none |
| `reconnecting`, attempt 4 or more, or longer than 10 s | `wifi.exclamationmark` "Can't reach chat.example. Retrying in 30 s" | Same, as a banner under the navigation bar | Queues | **Try Now** |
| No network route (`NWPathMonitor`) | `wifi.slash` "No internet connection" | Same | Queues | none. It reconnects when the path returns. |
| `retry_after` on connect | "chat.example is busy. Retrying in 30 s" | Same | Queues | none. Ladle must wait (§1.1). |
| `signedOut` after a refused resume | `person.crop.circle.badge.exclamationmark` "Signed out: <server message>" | Banner | "Sign in to send" | **Sign In** |
| `stopped(.denied)` | "chat.example refused the connection: <message>" | Banner | Disabled, with the reason | **Reconnect**, **Sign In** |
| `stopped(.rejected(403))` | "chat.example refused this app's origin (HTTP 403)" | Banner | Disabled, with the reason | **Edit Origin** |

**Pill timing** follows the web client so that it never flickers. It appears only after a check has taken 400 ms. It then stays at least 600 ms, and until 300 ms after the check ends. It takes no layout space. It uses `ProgressView` with text, not a spinner alone ([progress-indicators]: "Avoid vague terms like loading or authenticating"). VoiceOver hears state changes as low-priority announcements, at most one every 10 s.

**Foreground and background.**

- Idle (§4.5 `idle`), as apron-web's `PagePresence` on a handheld: after 5 minutes without a touch or typing, or on `scenePhase == .background`, each signed-in session with `status` sends `status {idle: <whole seconds since the last input>}`; the next touch or keystroke sends `status {idle: false}`. One request goes at a time, a refusal waits out its `retry_after`, and another failure retries from 5 s, doubling to 5 minutes. In the background a `beginBackgroundTask` covers the report (up to 3 s), and then the session stops.
- On `.active`, every session starts again, attended (a new connection starts attended, so nothing is sent), shows the cached view, and catches up behind the pill.
- iOS suspends a backgrounded app's socket anyway. Stopping on purpose makes the return predictable.

**Launch.** Ladle never alerts at launch ([alerts]: "Avoid showing an alert when your app starts."). It opens straight into the restored view with cached content (2.5).

### 4.2 Offline sending queues new messages

**Decision.** Ladle queues new messages and replies while the session is connecting or reconnecting. Everything else is disabled with a reason.

| Action while not live | Behavior | Reason |
|---|---|---|
| New message, reply | Queue in the room's outbox. Resend with the **same request `id` and params** on the next signed-in connection. | §1.2: "A retry SHOULD keep the same `id`, `method`, and `params`, also across reconnects." |
| Command | Disabled, with "Commands need a connection." | A command that runs minutes late can surprise people, such as `/kick`. |
| Edit, delete, reaction, join, leave, create | Hidden or disabled, with "Available when connected." | Each one depends on state that may have changed while offline. |
| Anything while signed out or stopped | Composer shows "Sign in to send". The outbox keeps its items. | Requests before `auth` get `denied` (§3.2.2). |

**Outbox rules.**

- **Pending row.** A queued message shows in the timeline at once, dimmed, with `clock` and "Sending…". VoiceOver says "Sending".
- **Identity.** A queued message sends only when the signed-in `user_id` matches the one that queued it. If you sign in as someone else, the message becomes "Not sent".
- **Order.** Each room sends its queue in order, one request at a time.
- **Errors.**
  - On `retry_after`, wait, then resend with the same `id`.
  - On `too_large`, return the text to the composer, with "Too long for this server."
  - On `denied` or `invalid_params`, show "Not sent" with the server's message.
  - A dropped connection leaves the message queued.
- **App exit.** The outbox is saved with the drafts (2.5). After a relaunch, items do not send by themselves. They show "Not sent" with **Retry**, which reuses the saved `id`, and **Delete**. **Judgment call.** A message written hours ago should not appear in a room without your say.
- **Never twice.** When the broadcast with your `message_id` arrives, the pending row is replaced in place.

**The risk, stated.** Deduplication is a SHOULD, and how long a server remembers an `id` is implementation-defined (§1.2). A server that does not deduplicate may log a resent message twice if the first attempt landed before the connection dropped. On `edit` servers you can delete the copy. Ladle does not try to detect duplicates by text.

**Kit change needed.** `Connection.request` makes a new `id` for each call, and `ServerSession` fails pending requests on close with no same-id resend. The outbox needs a caller-supplied `id` (gap 1).

### 4.3 Unread, mentions, badges, and notifications

**What Ladle counts.**

- **A count** is the number of messages Ladle holds in a joined room with `log_id` greater than your read position, excluding your own messages and `~private` notices. Live deliveries cover every joined room while connected. Catch-up covers opened rooms.
- **A dot** marks a joined room that Ladle has not loaded whose `latest_log_id` is greater than your read position. `latest_log_id` also advances for reactions and memberships, so Ladle cannot claim a number.
- **A mention** is a held message whose `body.mentions` contains your `user_id`, live or from catch-up after your read position. Text that merely contains your ID does not count. Messages loaded by paging older history never count.
- **Read position.** It moves to the newest message once you have scrolled to the bottom of a room for 1 s. It is stored per room. With `activity`, Ladle also sends `read_message_id` forward only, and applies cursors that the server sends for your own connections (§4.6).
- **Muted rooms** show the count in the secondary style and do not add to the section total. They still show `at` for mentions. **Judgment call.** Mute silences notifications (§4.5.3), so it should not hide that someone asked you something.

**App icon badge.** None in v1. Without push, iOS suspends Ladle shortly after it leaves the screen, and a badge could not stay correct ([notifications]: "Keep badges up to date."). Setting one would also need notification permission for no notifications.

**Notifications.** None in v1, and Ladle does not ask for notification permission. While Ladle is on screen, new messages arrive in place and counts update ([notifications]: "present the information in a way that's discoverable but not distracting or invasive"). Push needs a §4.9 relay with APNs (5.8).

### 4.4 Privacy

- Tokens live only in the Keychain, as one generic password per server id with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`KeychainStore`). [privacy] says "Store sensitive information in a keychain." They are never in `servers.json`, the message cache, logs, or state restoration.
- Kept history is one file per server with complete-until-first-auth protection, excluded from backup (2.5). Sign-out, a refused token, another account and server removal delete it.
- The camera purpose string is "Ladle uses the camera to scan sign-in QR codes, and to take photos and videos you attach to messages." It is a full sentence in sentence case, active voice, ending with a period ([privacy]: "Aim for a brief, complete sentence that's straightforward, specific, and easy to understand."). Ladle asks only when you tap Scan QR Code or take a photo or video.
- Ladle loads media where Preferences says (3.14): by default from the server's own origin, the origins it names with `ext:media`, and your trusted sites (§4.8.1, §5.5). Media in the timeline from anywhere else waits for a tap. Avatars and custom emoji from anywhere else don't load, so initials and keys show instead. `MediaGate.decide` is the one place this is decided.
- Ladle connects to a new server only after you tap Connect (§A.4).
- The token field is a `SecureField`. The token never appears on screen after you enter it.

[privacy] says "Avoid inventing custom authentication schemes." This conflicts with bearer-token paste. Ladle accepts the conflict because the protocol's reference scheme is `token` (§3.2), and passkeys are planned (5.8).

### 4.5 Haptics

One meaning per pattern, used only for events you cause ([playing-haptics]: "Use system-provided haptic patterns according to their documented meanings."). In SwiftUI, use `.sensoryFeedback`.

| Event | UIKit generator | `.sensoryFeedback` |
|---|---|---|
| Swipe-to-reply crosses its threshold | `UIImpactFeedbackGenerator(style: .light)` | `.impact(weight: .light)` |
| Reaction added or removed | `UISelectionFeedbackGenerator` | `.selection` |
| A scan, paste or link fills in a token | `.sensoryFeedback(.success)` | `.success` |
| Sign-in succeeded | `UINotificationFeedbackGenerator`, `.success` | `.success` |
| Sign-in, connect, or send failed while on screen | `UINotificationFeedbackGenerator`, `.error` | `.error` |

Never for these: incoming messages, mentions, typing, connection changes, paging, sending, or opening menus (the system already gives long-press feedback). Haptics never carry meaning on their own ([playing-haptics]: "Make haptics optional.").

### 4.6 Motion

- New messages insert with the system list animation. Ladle adds no bounce on send ([motion]: "In apps, generally avoid adding motion to UI interactions that occur frequently.").
- Jumping to a message scrolls with animation and highlights the target with a 1.5 s fade. Your touch interrupts the scroll ([motion]: "Let people cancel motion.").
- The swipe-to-reply row tracks your finger and springs back ([motion]).
- With Reduce Motion on, jumps scroll without animation, highlights become a static outline for 1.5 s, the typing dots hold still and dim, and the pill fades instead of sliding ([accessibility]: "Replacing transitions in x-, y-, and z-axes with fades").

### 4.7 iPad and hardware keyboard

- Support iPhone and iPad, and on iPhone every orientation except upside-down. The split view applies in regular width only (2.1).
- Multiple windows are allowed. Each window restores its own selection through `@SceneStorage`, and all windows share one `SessionStore`. "Open in New Window" is deferred.
- Shortcuts appear in the iPadOS menu bar through `.commands`, in a **Room** menu, and in the ⌘-hold overlay. Every shortcut has a touch path ([virtual-keyboards]: "A virtual keyboard doesn't support keyboard shortcuts.").

| Keys | Action |
|---|---|
| Return | Send (composer focused, hardware keyboard) |
| ⇧Return, ⌥Return | New line |
| ⌘Return | Send |
| Esc, ⌘. | Cancel reply or edit, close suggestions, close a sheet |
| ↑ (empty composer) | Edit your last message |
| ⌘F | Search rooms |
| ⌥⌘↑, ⌥⌘↓ | Previous or next room |
| ⇧⌥⌘↑, ⇧⌥⌘↓ | Previous or next unread room |
| ⌘↓ | Jump to latest |
| ⌘[ | Back |
| ⌘, | Settings for the current server ([settings]: people expect "the standard Command-Comma (,) keyboard shortcut to open an app's settings") |

Ladle overrides no standard shortcut ([keyboards]: "Respect standard keyboard shortcuts."). Rows, the timeline, and the composer must work with Full Keyboard Access. Rows get a hover effect, and secondary click opens the same context menus ([pointing-devices]).

### 4.8 What v1 leaves out, and why

| Left out | Why |
|---|---|
| Push notifications and the app icon badge | Push needs a §4.9 relay with APNs (AGENTS.md). Without push, a badge goes stale (4.3). |
| Sending attachments, `/avatar` uploads | `embed:upload` needs a photo picker, upload progress, and a cancel path. Receiving uploads is in v1. |
| Inline `iframe` and `html` embeds | Rendering them safely needs a sandboxed `WKWebView` that matches the §4.8 iframe sandbox. A mistake there exposes the token. They render as fallback cards. |
| Live stream reading | v1 shows the finished `text`. Reading the live `url` needs streaming HTTP and a reconnect rule. |
| Passkeys and external sign-in | AGENTS.md records the open questions about Apple's documentation. Token, email, and guest cover v1. |
| Message search | The protocol has no search request. Ladle could only search what it holds, which would look complete and not be. |
| Moving messages and select mode | Rare on a phone, and the web client covers it. Ladle shows moves correctly. |
| Edit history (`prev_log_id`) | Rarely needed. "Edited" is enough. |
| A browsable emoji picker | The system emoji keyboard covers any emoji (3.9). |
| An app-wide settings screen | Nothing app-wide needs a setting. Appearance and text size follow the system ([settings]: "Respect people's systemwide settings"). |
| Onboarding tips (TipKit) | Swipe to reply and long-press follow Messages, so they need no tip. Revisit after testing. |

## 5. Gap review of the current build

The review is ranked by how much each gap costs a person using the app. Paths are on `main`. On `design`, `Apron/` is `Ladle/` and `ApronApp.swift` is `LadleApp.swift`. "Kit" marks a change in `Packages/ApronKit` that the view change depends on.

1. **A failed send loses your text, and there is no outbox.** `Apron/Timeline/TimelineView.swift:35` clears the draft before `perform` runs, and an error only raises an alert. Kit: `Connection.request` (`Connection.swift:77`) mints a new `id` for each call, so a same-`id` resend is impossible. Spec 4.2, 3.7.
2. **Errors and sign-in interrupt as modals.** `RoomListView.swift:75` and `TimelineView.swift:63` use `.alert("Something went wrong")` for every failure. `RoomListView.swift:80` presents the sign-in sheet on appear whenever the session is signed out. Spec 3.0 states, 4.1.
3. **iPhone portrait only, with no split view, restoration, or deep links.** `project.yml` sets `TARGETED_DEVICE_FAMILY: "1"` and portrait only. `ApronApp.swift:13` shows a bare `ServerListView` in a `NavigationStack`. There is no `@SceneStorage`, no `apron` URL scheme, no `onOpenURL`, and no on-disk cache, so a relaunch shows empty rooms until the socket returns. Spec 2.
4. **No unread or mention state anywhere.** Room rows show only the title and "Not joined" (`RoomListView.swift` `RoomRow`). There is no read position, no New divider, and no jump-to-latest. Kit: no `activity` support. Spec 4.3, 3.1, 3.5.
5. **Notices and commands are missing.** `ServerSession.notices` (`ServerSession.swift:91`) fills but no view reads it, so welcome notices, `/help` output, and command errors never appear. Composer text that starts with `/` is posted as a message, against §4.1. Spec 3.5, 3.7.
6. **Protocol rendering bugs.**
   - `MessageRow.swift:35` shows reactions on tombstones (§4.4 says to hide them).
   - `MessageRow.swift:42` labels moved messages "Edited". Kit: `MessageSnapshot` drops `prev_room_id`.
   - `MessageRow.swift:72` says "Earlier message" where the target is unknown, instead of "Message unavailable", and the quote is not tappable.
   - Embeds are not rendered at all, so the unknown-kind fallback (§3.5.2 MUST) is missing.
   - Spec 3.5 protocol edges.
7. **No mentions.** The composer cannot mention anyone, rows do not mark mentions of you, and `ServerSession.send` (`ServerSession.swift:380`) takes no `mentions`. Spec 3.7, 3.5.
8. **Accessibility is default only.**
   - Message rows have no composed label, no custom actions, and no rotors.
   - Thread rows are indented with `.padding(.leading)` (`RoomListView.swift:41`), which VoiceOver does not convey.
   - Nothing adapts at accessibility sizes.
   - `MessageRow.swift:32` puts `.textSelection(.enabled)` on text that also has a context menu, which [context-menus] rules out.
   - Spec 3.0, 3.5, 3.8.
9. **Add Server and Sign In are two separate trips.** `ServerEditorView` asks for the address and shows Origin up front. Sign-in is a separate sheet. A link with `server` and `token` cannot create the server. The token field is a plain `TextField`. The email code uses `.numberPad` (`SignInView.swift:93`), which cannot take a pasted link. Spec 3.2, 3.3.
10. **Destructive actions have no confirmation.** **Remove** on a swipe (`ServerListView.swift:18`) and in the menu (`:23`), **Sign Out** (`RoomListView.swift:57`), and **Delete** in the message menu all act at once. Sign-out and removal lose a token-only account for good. Spec 3.12, 3.8.
11. **No identity, status, mute, or profile screens.** Kit: no `me`, `status`, or mute requests and no status in `UserObject` handling. Spec 3.10, 3.11.
12. **No lifecycle handling.** Nothing observes `scenePhase` or the network path. Reconnect timing is left to the socket's failure. Spec 4.1.
13. **Thread behavior is incomplete.** Threads are listed under rooms in the sidebar. There is no Threads list, no "Other threads", and no preview of an unjoined thread. Posting into an unjoined thread does not join first, so your own message never comes back to you (§4.2.2). The room order is by title in kit (`ServerSession.swift:467`), which matches the spec for rooms but not for threads. Spec 3.6.
14. **Reactions use an action sheet.** `TimelineView.swift:56` shows a `confirmationDialog` with six emoji, with no way to pick any other emoji, and the chips scroll sideways and show no names. Spec 3.9.
15. **No haptics and no keyboard shortcuts.** Return in the composer inserts a new line on a hardware keyboard, and nothing sends. Spec 4.5, 4.7.
16. **Silent persistence errors.** `ApronApp.swift:8` drops `store.load()` errors with `try?`. `SessionStore.saveError` is never shown. Show a one-line notice in Rooms when the server list cannot be read or saved.
17. **Copy that says "we" or uses jargon.** For example, "Sent as the Origin header" appears without context, and the token footer names `/invite-bot`. Spec 3.2 and 3.3 give the replacement strings ([writing], [inclusion]).

### 5.1 Status on the `design` branch

The web-parity pass (2026-10-28) closed most of the list. "Partial" names what is left.

| Gap | Status |
|---|---|
| 1. Outbox | Closed in memory: `ServerSession.post` queues with one request `id` per message, resends it across reconnects and timeouts, and shows "Sending…" or "Not sent" with Retry and Delete. Partial: the outbox is not saved across launches, and `too_large` marks the message "Not sent" instead of returning the text to the composer. |
| 2. Modal errors and sign-in | Closed. Failures are inline banners; sign-in is a banner with **Sign In**, never a sheet that opens itself. |
| 3. iPad, rotation, restoration, links | Partial. iPad split view, landscape, `@SceneStorage` for the open server and room, and `apron:` and link.apron.chat links are in, and kept history shows a relaunch's rooms at once (2.5). |
| 4. Unread and mentions | Closed. Counts, `@` counts, the New line, and the jump bar. |
| 5. Notices and commands | Closed. Notices show as callouts; `/` sends a `command`, `//` a message. |
| 6. Rendering bugs | Closed. |
| 7. Mentions | Closed. |
| 8. Accessibility | Closed for the listed items. Rotors are not added. |
| 9. Add Server and Sign In | Closed. One Connect sheet. |
| 10. Confirmations | Closed. |
| 11. Identity, status, mute, profile | Partial. You (3.11) edits the name, bio and avatar and picks a status; the profile card (3.10) and the server pane (3.12) are in. Mute and pause are not. |
| 12. Lifecycle | Partial. Sessions report idle and stop in the background, start in the foreground, and a returning network reconnects; after 5 minutes without input they report idle while open. |
| 13. Threads | Partial. Posting into an unjoined room joins first. No Threads list, "Other threads", or unjoined-thread preview. |
| 14. Reactions | Closed. Frequent six plus the system emoji keyboard; who reacted on long press and in VoiceOver. |
| 15. Haptics and keyboard | Partial. Return sends and Shift-Return is a new line with a hardware keyboard; a light haptic on send. The other shortcuts and haptics in 4.5 and 4.7 are not added, and swipe to reply (principle 3) is not built. |
| 16. Persistence errors | Closed. A callout on the server list. |
| 17. Copy | Partial. The token footer is 3.3's string. The origin footer is new plain wording ("A token works only from the website that gave it to you…"), not 3.2's, and the rest of 3.2 and 3.3's error strings are not all in. |

## HIG pages read

All pages were fetched on 2026-10-27 from `https://developer.apple.com/tutorials/data/design/human-interface-guidelines/<page>.json`. The human-readable URL is `https://developer.apple.com/design/human-interface-guidelines/<page>`.

| Page | Used for |
|---|---|
| [layout] | Size classes, Dynamic Type stacking, safe areas |
| [navigation-and-search] | Index page only. Its children (sidebars, tab bars, search fields) carry the guidance. |
| [tab-bars] | Why there are no tabs |
| [sidebars] | Two levels, disclosure sections |
| [split-views] | Regular-width split view, selection |
| [toolbars] | Titles, item count |
| [lists-and-tables] | Row content, selection |
| [sheets] | Detents, one sheet at a time, Cancel placement |
| [menus] | Order, checkmarks |
| [context-menus] | Main-interface parity, destructive last, no edit menu as well |
| [keyboards] | Standard shortcuts, custom shortcuts |
| [virtual-keyboards] | Return key, keyboard layout guide |
| [text-fields] | Secure fields, keyboard types |
| [buttons] | 44 pt, prominence, progress |
| [gestures] | Familiar gestures, system gestures |
| [playing-haptics] | Haptic meanings and restraint |
| [feedback] | Status in the interface |
| [loading] | Show something at once |
| [progress-indicators] | Automatic updates, wording |
| [alerts] | No informative or launch alerts |
| [action-sheets] | Confirming destructive actions |
| [popovers] | Not in compact width |
| [modality] | Sign-in as one path |
| [onboarding] | No tour, permission at need |
| [managing-accounts] | Offered methods only, delay sign-in |
| [privacy] | Keychain, purpose string, custom auth |
| [accessibility] | Contrast, targets, gesture alternatives, Reduce Motion |
| [voiceover] | Labels, grouping, rotors |
| [typography] | Dynamic Type layout |
| [color] | No color-only state |
| [dark-mode] | Contrast, no app appearance setting |
| [motion] | Restraint, cancellable motion |
| [sf-symbols] | Variants, slash for muted |
| [notifications] | Badge honesty, foreground handling |
| [managing-notifications] | Deferred push design |
| [designing-for-ios] | Reach, focus on content |
| [launching] | Restore state |
| [multitasking] | Save context continuously |
| [settings] | Few settings, ⌘, |
| [searching], [search-fields] | Bottom search, filter as you type |
| [writing] | Error copy, next steps |
| [inclusion] | Define technical terms |
| [file-management] | Quick Look |
| [right-to-left] | Mirrored gestures |
| [pointing-devices] | Pointer parity |
| [edit-menus], [undo-and-redo], [entering-data], [pull-down-buttons], [segmented-controls], [toggles], [materials], [offering-help], [collaboration-and-sharing], [drag-and-drop], [going-full-screen], [camera-control] | Read. These shaped nothing beyond the pages above, or were out of scope for v1. `camera-control` covers the hardware button, not scanning. |

`live-text` returned HTTP 404. The HIG has no page on QR or Live Text scanning, so 3.3's scanner design is a judgment call that rests on [privacy] for the permission.

[layout]: https://developer.apple.com/design/human-interface-guidelines/layout
[navigation-and-search]: https://developer.apple.com/design/human-interface-guidelines/navigation-and-search
[tab-bars]: https://developer.apple.com/design/human-interface-guidelines/tab-bars
[sidebars]: https://developer.apple.com/design/human-interface-guidelines/sidebars
[split-views]: https://developer.apple.com/design/human-interface-guidelines/split-views
[toolbars]: https://developer.apple.com/design/human-interface-guidelines/toolbars
[lists-and-tables]: https://developer.apple.com/design/human-interface-guidelines/lists-and-tables
[sheets]: https://developer.apple.com/design/human-interface-guidelines/sheets
[menus]: https://developer.apple.com/design/human-interface-guidelines/menus
[context-menus]: https://developer.apple.com/design/human-interface-guidelines/context-menus
[keyboards]: https://developer.apple.com/design/human-interface-guidelines/keyboards
[virtual-keyboards]: https://developer.apple.com/design/human-interface-guidelines/virtual-keyboards
[text-fields]: https://developer.apple.com/design/human-interface-guidelines/text-fields
[buttons]: https://developer.apple.com/design/human-interface-guidelines/buttons
[gestures]: https://developer.apple.com/design/human-interface-guidelines/gestures
[playing-haptics]: https://developer.apple.com/design/human-interface-guidelines/playing-haptics
[feedback]: https://developer.apple.com/design/human-interface-guidelines/feedback
[loading]: https://developer.apple.com/design/human-interface-guidelines/loading
[progress-indicators]: https://developer.apple.com/design/human-interface-guidelines/progress-indicators
[alerts]: https://developer.apple.com/design/human-interface-guidelines/alerts
[action-sheets]: https://developer.apple.com/design/human-interface-guidelines/action-sheets
[popovers]: https://developer.apple.com/design/human-interface-guidelines/popovers
[modality]: https://developer.apple.com/design/human-interface-guidelines/modality
[onboarding]: https://developer.apple.com/design/human-interface-guidelines/onboarding
[managing-accounts]: https://developer.apple.com/design/human-interface-guidelines/managing-accounts
[privacy]: https://developer.apple.com/design/human-interface-guidelines/privacy
[accessibility]: https://developer.apple.com/design/human-interface-guidelines/accessibility
[voiceover]: https://developer.apple.com/design/human-interface-guidelines/voiceover
[typography]: https://developer.apple.com/design/human-interface-guidelines/typography
[color]: https://developer.apple.com/design/human-interface-guidelines/color
[dark-mode]: https://developer.apple.com/design/human-interface-guidelines/dark-mode
[motion]: https://developer.apple.com/design/human-interface-guidelines/motion
[sf-symbols]: https://developer.apple.com/design/human-interface-guidelines/sf-symbols
[notifications]: https://developer.apple.com/design/human-interface-guidelines/notifications
[managing-notifications]: https://developer.apple.com/design/human-interface-guidelines/managing-notifications
[designing-for-ios]: https://developer.apple.com/design/human-interface-guidelines/designing-for-ios
[launching]: https://developer.apple.com/design/human-interface-guidelines/launching
[multitasking]: https://developer.apple.com/design/human-interface-guidelines/multitasking
[settings]: https://developer.apple.com/design/human-interface-guidelines/settings
[searching]: https://developer.apple.com/design/human-interface-guidelines/searching
[search-fields]: https://developer.apple.com/design/human-interface-guidelines/search-fields
[writing]: https://developer.apple.com/design/human-interface-guidelines/writing
[inclusion]: https://developer.apple.com/design/human-interface-guidelines/inclusion
[file-management]: https://developer.apple.com/design/human-interface-guidelines/file-management
[right-to-left]: https://developer.apple.com/design/human-interface-guidelines/right-to-left
[pointing-devices]: https://developer.apple.com/design/human-interface-guidelines/pointing-devices
[edit-menus]: https://developer.apple.com/design/human-interface-guidelines/edit-menus
[undo-and-redo]: https://developer.apple.com/design/human-interface-guidelines/undo-and-redo
[entering-data]: https://developer.apple.com/design/human-interface-guidelines/entering-data
[pull-down-buttons]: https://developer.apple.com/design/human-interface-guidelines/pull-down-buttons
[segmented-controls]: https://developer.apple.com/design/human-interface-guidelines/segmented-controls
[toggles]: https://developer.apple.com/design/human-interface-guidelines/toggles
[materials]: https://developer.apple.com/design/human-interface-guidelines/materials
[offering-help]: https://developer.apple.com/design/human-interface-guidelines/offering-help
[collaboration-and-sharing]: https://developer.apple.com/design/human-interface-guidelines/collaboration-and-sharing
[drag-and-drop]: https://developer.apple.com/design/human-interface-guidelines/drag-and-drop
[going-full-screen]: https://developer.apple.com/design/human-interface-guidelines/going-full-screen
[camera-control]: https://developer.apple.com/design/human-interface-guidelines/camera-control
