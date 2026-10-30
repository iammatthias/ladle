# Stateless views: audit

Ladle's views should render the values they are given and call closures. Behaviour, derived
state and side effects belong in plain model types, mostly in ApronKit, where `swift test`
reaches them. apron-web did this for its message field in #159 (`DraftField`, shared by the
composer and the message editor). This audit lists every view in `Ladle/` with a verdict, as of
`eae9d0d`:

- **stateless**: renders its inputs; no change.
- **extract**: holds logic that moves to a named model; the entry says what moves and what the
  view keeps.
- **keep**: holds state, but the state is the view's own (focus, scroll position, a sheet or
  dialog being shown, a player, a decoded image), or the logic is UIKit or SwiftUI glue.

Line numbers are at `eae9d0d`.

## Order of the extractions

1. **Timeline derivations** move to ApronKit. `Timeline/TimelineItems.swift` is a
   `ServerSession` extension built only on Foundation, in the app target where no test reaches
   it. The draft field and the row model below need `memberSections`, `plainText` and
   `mentionIDs` in ApronKit, so this move comes first.
2. **`DraftField`**: the composer's text, mentions, active query, suggestions, insertion and
   send. The composer in edit mode uses the same model.
3. **`MessageReminders`**: Remind Me's key, set and remove, and the notifications-off notice,
   out of `TimelineView`.
4. **`MessageMenu`**: what a message's and a notice's menus offer, out of `TimelineView`.
5. **`MessageRowModel`**: place cards, embed filtering, the fetched preview's slot, mentions and
   the spoken text, out of `MessageRow`; mention runs marked by `MessageText` as room chips are.
6. **`ConnectForm`**: the Connect sheet's form rules, out of `ConnectView`.
7. **`LinkRoute`**: what an Apron link or a tapped reminder opens, out of `RootView`.
8. **`ConnectionState`** moves to ApronKit: a status-to-words mapping that four views read.

## The message editor

Ladle has no separate message editor: Edit puts the composer in edit mode
(`TimelineView.swift:342`, `Draft(mode: .edit(message), text: message.plainText)`). The `@`,
`:` and `#` lists already show in edit mode, since only the command query checks for an edit
(`ComposerView.swift:283-286`). What an edit lacks is its mentions:

- An edit starts with no mentions (`TimelineView.swift:342`), so picking someone in an edit is
  forgotten.
- `ServerSession.edit(_:text:)` sends `body.mentions` as stored (`ServerSession.swift:780-787`),
  whatever the new text says.

With `DraftField`, an edit opens with the message's mentions whose `@name` or `@user_id` is in
its text, and saves the mentions its text still holds, picked ones included. This follows
§3.5.5 and §4.4 (a save replaces `body.mentions`; only users it adds are mentioned again), as
apron-web's #159 does. Ladle's field is a `TextField`, not an editable with chips; a mention is
`@Name` in the text and an entry in the draft's mentions, and the row draws it as a chip once
`body.mentions` lists it. `/` commands stay composer-only.

## Verdicts

### App

| View | Verdict | Evidence and decision |
| --- | --- | --- |
| `LadleApp` (`App/LadleApp.swift`) | keep | The `App` entry: creates the `SessionStore` and its load error once (`:7-9`). |
| `RootView` (`App/RootView.swift:10`) | extract | `open(_:)` (`:110-123`) decides what a link opens: a saved server's sign-in sheet with the token, a place on a saved server, or the Connect sheet for a new one. `openReminder()` (`:126-131`) turns a tapped reminder's key into a link on its server. Both move to `LinkRoute` in ApronKit, built from the saved records. The view keeps `path`, `connecting`, `place`, the `@SceneStorage` selection, `restore()` (rebuilding the navigation path is navigation state), the scene-phase start and stop (`:48-57`) and `watchNetwork()` (`:142-156`, an `NWPathMonitor` lifetime tied to the view). |
| `ResolvingLinks` (`App/RootView.swift:167`) | stateless | Wraps `openURL` with `ApronLink.outbound`, which is already in ApronKit. |
| `SplitLayout` (`App/RootView.swift:181`) | stateless | Lays out the rail, rooms and timeline from bindings. `server(_:in:)` (`:223-226`) picks the saved selection or the first server; one line, kept. |
| `ErrorText` (`App/ErrorText.swift`) | keep | Words for errors; the app's copy, not protocol behaviour. |
| `ReminderRoutes`, `LocalReminderNotifier`, `AppDelegate` (`App/ReminderNotifications.swift`) | keep | UserNotifications glue. |

### Design

| View | Verdict | Evidence and decision |
| --- | --- | --- |
| `UnreadCount`, `Lock`, `Callout`, `ActionBanner`, `EmptyState`, `PrimaryButtonStyle`, `GhostButtonStyle`, `SectionHead`, `TimelineDivider` (`Design/Components.swift`) | stateless | Draw their inputs. |
| `Palette`, `TextRole`, `ScaledRole`, `TypeTable`, `Motion`, `Appearance` (`Design/Apron.swift`) | stateless | Design tokens and the Dynamic Type table, SwiftUI by nature. |
| `StatusDot`, `RoleBadges` (`Design/People.swift`) | stateless | Draw their inputs. `Presence` (`:8-33`) carries a `Color`, so it stays with the design. |
| `Avatar` (`Design/People.swift:69`) | keep | Its image view holds the decoded image (`:144`). `initials`, `hue` and `oklch` (`:161-212`) are drawing math for this view alone. |
| `Tokens`, `TokenTypes` | stateless | Generated tokens. |

### Media

| View | Verdict | Evidence and decision |
| --- | --- | --- |
| `MediaViewer` (`Media/MediaViewer.swift:39`) | keep | `selection` (`:41`) is the page shown. `ServerSession.mediaItems(in:)` (`:21-37`) is Foundation-only derived state and moves with the timeline derivations (step 1); `MediaItem` moves with it. |
| `ZoomablePage`, `ZoomableImage` (`Media/MediaViewer.swift:97`, `:122`) | keep | The loaded image and the UIKit zoom view. |
| `RemoteImage`, `MediaLoader` (`Media/MediaLoader.swift`) | keep | Image decoding and its cache, UIKit by nature. |

### Rooms

| View | Verdict | Evidence and decision |
| --- | --- | --- |
| `RoomListView` (`Rooms/RoomListView.swift:10`) | keep | Grouping and sorting are already `ServerSession.roomTree` in ApronKit (`:35`). Its state is presentation: the browse sheet, the new-room alert and its title field, the leave and sign-out dialogs, the avatar picker, the problem banner (`:15-23`). `bannerView` (`:134-156`) picks among the problem, a sign-in prompt and `ConnectionState`, which is step 8. `setAvatar` (`:200-211`) chains a PhotosPicker item into `AttachmentPreparer.prepareAvatar` and `session.setAvatar`, both in ApronKit; what is left is the picker glue. |
| `RoomRow` (`Rooms/RoomListView.swift:221`) | stateless | Reads counts and titles from the session (`:228-231`); the badge choice (`:261-267`) is drawing. |
| `BrowseRoomsView` (`Rooms/RoomListView.swift:315`) | keep | Holds the listing it fetched once (`:318-319`, `:357-362`) for the sheet's lifetime. |

### Servers

| View | Verdict | Evidence and decision |
| --- | --- | --- |
| `ConnectView` (`Servers/ConnectView.swift:10`) | extract | The sign-in and connect sheet holds a form model: the offered methods (`:308-313`), whether it can submit (`:330-337`), the button's word (`:322-328`), whether the token is a sign-up invite (`:320`), the address check (`:339-344`), the origin following the address (`:83-87`), loading a saved record (`:346-357`), applying a scanned or pasted sign-in (`:360-389`), the `SignIn` to send (`:411-426`), and the record to save (`:438-452`). These move to `ConnectForm` in ApronKit, a value type. The view keeps the fields' bindings, `scanning`, `showsOrigin`, `working`, the error line, and `submit()`'s wait for the server's greeting and its call to the session, which own the sheet's lifetime and dismissal. |
| `ServerListView`, `ServerRow`, `RailTile`, `ServerRail`, `NoServers`, `HostYourOwnLink` (`Servers/ServerListView.swift`) | keep | The server rail and list. Their state is the remove dialog (`:12`, `:124`). `ServerRow.statusText` (`:82-87`) and the rail's counts (`:154-155`) are one-line reads of the session; `ConnectionState` (step 8) supplies the words. |
| `ConnectRequest` (`Servers/ServerListView.swift:212`) | keep | The Connect sheet's item: presentation. |
| `QRScanner`, `QRScannerView` (`Servers/QRScannerView.swift`) | keep | VisionKit glue; `rejected` (`:10`) is the scanner's own message. |
| `KeychainStore` | keep | The Keychain `TokenStore`. |

### Settings

Ladle has no settings view: Show Link Previews is `Settings.bundle`, read with `@AppStorage` in
`FetchedLinkCard` (`Timeline/FetchedLinkCard.swift:60`). Nothing to extract.

### Timeline

| View | Verdict | Evidence and decision |
| --- | --- | --- |
| `TimelineItem` and the `ServerSession` and `MessageSnapshot` extensions (`Timeline/TimelineItems.swift`) | extract | Not a view: `timelineItems` (`:28-61`), `threadIDs`, `mentionCount` (`:68-74`), `isPrivate`, `roomDescription`, `memberSections` (`:83-89`), and `date`, `isEdited`, `plainText`, `mentionIDs`, `mentions` on `MessageSnapshot` (`:92-105`). Foundation only, untested, in the app target. They move to ApronKit unchanged (step 1), with `mediaItems(in:)`, `needsEmojiCatalog`, `loadEmojiCatalog(for:)` (`Timeline/CustomEmojiViews.swift:168-181`) and `spoken` (`Timeline/MessageRow.swift:182-189`). |
| `ComposerView` (`Timeline/ComposerView.swift:18`) | extract | The queries (`:283-309`), their precedence over empty results (`:34-50`), the candidates (`:317-323`), the insertions (`:289-292`, `:312-315`, `:325-330`, and `roomQuery`'s insert closure at `:47`), which mentions go (`:335`), `canSend` (`:276-280`) and `target`/`isEdit` (`:264-274`) move to `DraftField`. The command, post or edit dispatch in `TimelineView.send` (`TimelineView.swift:429-445`) moves to `ServerSession.submit`. The view keeps `@FocusState`, the pickers and camera (`:25-29`), the recorder, attachment staging (`:215-248`: Photos, files and the camera are app frameworks), the placeholder words, and the `.task`s that load commands and the emoji catalog when a query of that kind opens. |
| `RoomSuggestions`, `MentionPicker` (`Timeline/ComposerView.swift:342`, `:378`) | stateless | Draw a list and call `pick`. |
| `CommandSuggestions` (`Timeline/ComposerView.swift:420`) | keep | `height` (`:423`) is its measured height, layout state. |
| `TimelineView` (`Timeline/TimelineView.swift:8`) | extract | Reminders: `reminderKey` (`:361-363`), the `remind` and `forget` Tasks (`:365-376`) and `notificationsOff` (`:28`) move to `MessageReminders` (step 3), which also gives Custom…'s starting time (`:354`). The menus: which actions a message offers and when (`:309-345`), Remind Me's entries (`:349-359`), a body's link actions (`:380-389`), a notice's actions and title (`:395-404`, `:447-454`) move to `MessageMenu` (step 4). Sending moves to `ServerSession.submit` (step 2). The view keeps presentation state: `focus`, `highlighted`, `jumpTarget` (a link's scroll and highlight, `:174-191`), `draft`, `problem`, `reacting`, `deleting`, `leaving`, `showingMembers`, `viewing`, `selecting` and `remindingAt` (sheets), `atBottom`, `visible`, `visit` and `sentCount` (`:12-27`). The scroll and read position stay: `atBottom` comes from the scroll geometry (`:72-76`), `isReading` (`:193-195`) combines it with visibility and the scene phase, and the read itself is `ServerSession.markRead`, already in ApronKit. `Visit` (`:488-501`) is already a small model of the visit's New line. `dropped` (`:412-427`) stages files as the composer does. `dayLabel` (`:456-461`) is the app's words for a date. |
| `SelectableBody`, `CustomReminder` (`Timeline/TimelineView.swift:514`, `:522`) | keep | The Select Text and Custom… sheets' items: presentation. `SelectableBody`'s text (`MessageText.plain`) comes from `MessageMenu`; `CustomReminder`'s first time comes from `MessageReminders`. |
| `Draft` (`Timeline/TimelineView.swift:471`) | extract | Its mode, text and mentions become `DraftField`; the app's `Draft` keeps the field and the staged attachments (`DraftAttachment` holds an app-side preparation phase). |
| `Focus`, `ReadMark`, `MediaRequest` (`Timeline/TimelineView.swift:503`, `:508`, `:529`) | keep | Task and sheet identities. |
| `MembersPresentation`, `JumpBar`, `TightLabel`, `PendingRow`, `ReadOnlyPrompt` (`Timeline/TimelineView.swift`) | stateless | Draw their inputs and call closures. |
| `ThreadCard` (`Timeline/TimelineView.swift:590`) | stateless | Reads the thread's messages; `faces` (`:598`) is the drawing's three most recent senders. |
| `ConnectionState` (`Timeline/TimelineView.swift:692`) | extract | A pure mapping from `ServerSession.Status` to a symbol and words, read by `TimelineView`, `RoomListView`, `ServerRow`, `ServerRail` and `ConnectView`. It moves to ApronKit (step 8) with tests on its words. |
| `MessageRow` (`Timeline/MessageRow.swift:8`) | extract | `mentionsYou` (`:28`), the place cards (`:114`, computed again at `:167`), the embeds a card previews (`:126`, again at `:169`), the fetched preview and the embed it replaces (`:123-128`), `mentionNames` (`:152-156`) and the spoken text (`:158-178`) move to `MessageRowModel` in ApronKit, built from the session, the message and the other servers' sessions (step 5). `rendered()` (`:194-215`) splits: `MessageText` marks mention runs with a `MentionKey`, as it marks room chips, and the app colours the marked runs. The view keeps the layout, the type-size switch (`:27`) and the emoji catalog task. |
| `ReplyQuote`, `ReactionBar`, `FlowLayout`, `WrittenDirection` (`Timeline/MessageRow.swift`) | stateless | Draw their inputs; `FlowLayout` is layout math. |
| `PlaceCardView` (`Timeline/PlaceCardView.swift`) | stateless | Draws a `PlaceCard`. |
| `EmbedView`, `UploadEmbedView`, `PendingUploadCard`, `FileGlyph`, `EmbedCard`, `LinkCard`, `LinkButton` (`Timeline/EmbedViews.swift`) | stateless | Draw an `Embed`. `kindLabel` and `summary` (`:376-392`) are the app's words. |
| `FileCard`, `VideoTile`, `AudioCard` (`Timeline/EmbedViews.swift:121`, `:191`, `:242`) | keep | A Quick Look file being fetched, an `AVPlayer` and its play state (`:125-127`, `:204`, `:247-249`): player lifetime belongs to the view. |
| `FetchedLinkCard` (`Timeline/FetchedLinkCard.swift:56`) | keep | Holds the preview it fetched and its decoded image (`:61`); the fetching and caching are `LinkPreviews` in ApronKit. |
| `EmojiText`, `ReactionGlyph`, `EmojiSuggestions`, `EmojiTile`, `EmojiImages` (`Timeline/CustomEmojiViews.swift`) | stateless | Draw custom emoji; `EmojiImages` is an image cache. |
| `AttachmentTray`, `AttachmentTile` (`Timeline/Attachments.swift:86`, `:107`) | stateless | Draw the staged files. |
| `AttachmentStaging`, `ImportedFile`, `CameraPicker` (`Timeline/Attachments.swift`) | keep | Staging folders, `Transferable` and `UIImagePickerController` glue; the plans are `AttachmentPreparer` and `UploadPlan` in ApronKit. |
| `MemberList` (`Timeline/MemberList.swift`) | stateless | Reads `memberSections`, which moves to ApronKit in step 1. |
| `ReactionPicker` (`Timeline/ReactionPicker.swift`) | stateless | `groups` (`:66-73`) folds the catalog's offered emoji by category for the grid; it stays beside the grid it shapes. `EmojiField` is UIKit glue. |
| `ReminderBadge`, `ReminderDateSheet` (`Timeline/ReminderViews.swift`) | stateless | Draw a due time from `Reminder.label` and a date binding. |
| `SelectTextSheet`, `SelectableText` (`Timeline/SelectTextSheet.swift`) | stateless | Show text in a read-only `UITextView`. |
| `VoiceRecorder`, `RecordingBar` (`Timeline/VoiceRecorder.swift`) | keep | AVFoundation recording state. |
| `MediaCompression` (`Timeline/MediaCompression.swift`) | keep | AVFoundation export. |

## Outcome

Each step above landed as one commit, with its tests in `Packages/ApronKit/Tests/ApronKitTests/`:

1. `Timeline.swift` (`TimelineTests`). `Presence` moved too, its color staying in the app.
2. `DraftField` and `ServerSession.suggestions(for:in:)` and `submit` (`DraftFieldTests`, and
   `testAnEditSavesWhoItsTextStillMentions` in `ServerSessionTests`).
3. `MessageReminders` (`MessageRemindersTests`). `TimelineView` takes the store's
   `Reminders` as an argument; the `reminders` environment value is gone.
4. `MessageMenu`, and `NoticeMenu` for a notice's menu and title (`MessageMenuTests`).
5. `MessageRowModel` and `MentionKey` (`MessageRowModelTests`), with the spoken helpers:
   `EmojiKeys.spoken`, `ReactionEntry.label`, `PlaceCard.spoken`, `Embed.kindLabel` and
   `summary`.
6. `ConnectForm`, and `SessionStore.save` for the record (`ConnectFormTests`).
7. `LinkRoute` (`LinkRouteTests`).
8. `ConnectionState` (`ConnectionStateTests`).

The design shots render as they did at `eae9d0d`: 51 of the 52 PNGs are byte-identical, and
the last differs only in the reaction picker field's text cursor, which blinks. Across the
intermediate runs, the servers shot's unread count for the
demo server varies between runs of the same build (its `help` room is sometimes counted
unread while the fixtures load); a second render of `eae9d0d` and a debug run of the new
code each showed both values, so it does not come from these changes.
