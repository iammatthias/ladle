# Ladle privacy policy

Ladle is a client for Apron chat servers. It collects no data.

- **No accounts with us.** Ladle has no servers of its own. It connects only to the Apron servers you add, and those servers' operators set their own policies.
- **What stays on your device.** The servers you add and their sign-in tokens. The tokens are kept in the iOS Keychain. Delete the app to remove them.
- **What goes to your servers.** What any chat client sends: your messages, reactions, display name and the rooms you join. Ladle sends it only to the server you're using.
- **Link previews.** When **Show Link Previews** is on (Ladle's page in the Settings app; it's on by default), your device fetches a preview of a link in a message: the linked page's title and image, straight from that site, which sees your IP address as it would if you opened the link. Ladle fetches a preview only when the message comes into view and the server sent none, never for Apron links or links that name a computer on your own network. Previews are kept in the app's cache on your device for up to a week. Turn the setting off to stop these fetches; previews your server provides still show.
- **Reminders.** When you set Remind Me on a message, Ladle keeps the reminder on your device (which server, room and message, when it is due, and the sender's name and the message's first line for the alert) and schedules a notification on your device for that time. Nothing about a reminder goes to any server, and Ladle asks to send notifications only the first time you set one. Removing a reminder, or the server, deletes it and its notification.
- **No tracking.** Ladle has no analytics, advertising, crash reporting or third-party SDKs.
- **Camera, microphone and photos.** The camera scans a sign-in QR code when you choose to; no image from a scan is stored or sent. Otherwise they're used only for a photo, video, voice note or file you choose to attach, which goes only to the server you send it to.

Questions: open an issue on the project's repository.
