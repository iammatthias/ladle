# Push while Ladle is closed

Ladle alerts while it runs from its own connection (Preferences > Notifications). To alert while it is closed, a server must push (PROTOCOL.md §4.9), and an iOS app can only receive pushes through Apple Push Notification service (APNs). APNs accepts pushes only from someone holding the app's APNs key, so a server cannot push to Ladle directly. A relay in between holds the key: each server posts to the relay, and the relay posts to APNs.

Everything on Ladle's side is built and off. This document says what Ladle does, what the relay must do, and the steps only the owner can take.

## What Ladle does

1. A build with `LADLE_PUSH` set (below) has the `aps-environment` entitlement, registers for remote notifications at launch, and gets an APNs device token.
2. With a relay set in Preferences > Notifications > Push Relay, Ladle asks the relay for an endpoint for that token: `POST <relay>/v1/register` with `{"device_token": "<hex>", "environment": "development" | "production", "topic": "app.ladle.ios"}`. The relay answers `200` with `{"url": "https://…", "token": "…"}`. `url` must be https. `token` is optional.
3. After each sign-in, for each account that is not a guest, on a server whose `server.push` has `relay`, with the Notifications switch on, Ladle sends:

   ```json
   {"method": "push_register", "params": {"kind": "relay", "url": "<url>", "token": "<token>",
     "push_id": "<16 characters>", "wake": ["mentions", "replies", "private"]}}
   ```

   `push_id` is random per account and server. `wake` is the checked Notify Me About scopes that `server.push.wake` lists. When the server lists none, `wake` is left out and the server's defaults apply. A change of scope registers again with the same `url`. Signing out, or turning the switch off, sends `push_unregister`.
4. No `keys` go with the registration, so the server posts the payload to the relay as plain JSON (§4.9.2).
5. A tapped push opens its message, revealed and highlighted (apron-web #203). Ladle finds the account by `push_id` and reads `room_id` and `message_id` from the payload.
6. A push that comes while Ladle is in front shows nothing. The connection brings the message, and Ladle alerts for it if it should.
7. A message notification raised from the connection has the identifier `apron:<push_id>:<message_id>` and the thread `<push_id>:<room_id>`. If the relay uses the same `apns-collapse-id` and `thread-id`, a push and a local alert for one message show once, and reading a room closes both.

## What the relay does

The relay is a small HTTPS service. It holds the APNs key, and nothing else in this setup does.

- `POST /v1/register`: the request in step 2. Keep `{device_token, environment, topic}` under a new random id. Answer `{"url": "https://<relay>/p/<id>", "token": "<random secret>"}`. Registering the same device token again may return the same id.
- `POST /p/<id>`, from Apron servers: check `Authorization: Bearer <token>` against the id's secret, and answer `401` otherwise. The body is the §4.9.3 payload, at most 2048 bytes:

  ```json
  {"push_id": "t65S5XBst9bSDpjJ", "unread": 2,
   "message": {"message_id": "1724803200042", "room_id": "general",
               "from": {"user_id": "alice", "name": "Alice"}, "body": {"text": "Deploy is done"}}}
  ```

  Send one APNs request to `https://api.push.apple.com` (production) or `https://api.sandbox.push.apple.com` (development), at `/3/device/<device_token>`:

  - Headers: `authorization: bearer <JWT>`, an ES256 JWT signed with the `.p8` key, with `kid` the Key ID and `iss` the Team ID, renewed at most once every 20 minutes and at least once an hour. `apns-topic: app.ladle.ios`. `apns-push-type: alert` (Apple's type for anything that shows, sounds or sets the badge). `apns-priority: 10` with a `message`, else `5`. `apns-collapse-id: apron:<push_id>:<message_id>` with a `message`.
  - Body with a `message`: `{"aps": {"alert": {"title": "<from.name or from.user_id> · <room_id>", "body": "<body.text on one line, or New message>"}, "sound": "default", "badge": <unread>, "thread-id": "<push_id>:<room_id>"}, "apron": "<the payload's JSON text>"}`. Put `apron` in as a string. Ladle parses it on tap.
  - Body without a `message` (a badge push, after you read on another device): `{"aps": {"badge": <unread>}}`, which sets the badge and shows nothing.
- Answer the Apron server `201` once APNs accepts. If APNs answers `410` or `400 BadDeviceToken`, delete the id and answer `410`. The server then removes the registration (§4.9.1).
- Keep no message content. The relay sees each message's sender, room and text in plain JSON while it forwards them.

The relay can run beside aprond on the same host, behind the same Caddy, at its own name. It has no Apron state.

## Recommendation: which push kind

Two designs reach APNs through a relay.

1. **Kind `relay` (§4.9.2), what Ladle registers now.** The spec defines it for native apps. aprond offers it, with the `badge` scope, so a read on another device clears the badge here. Without `keys` the relay reads the payload, and Ladle needs no extension.
2. **Kind `webpush`, pointed at the relay.** Every Apron server speaks `webpush`, including apron-server-cloudflare and the public demo, which do not offer `relay`. `keys` are required, so the payload is encrypted end to end (RFC 8291) and the relay cannot read it. A Notification Service Extension decrypts it on the device. Servers ignore `badge` for `webpush`, so there are no badge-only pushes.

Both need the server's operator to allow the relay host. aprond's `--push.hosts` and apron-server-cloudflare's `PUSH_HOSTS` both default to the browsers' push services only. So `webpush` does not reach servers the owner does not run unless their operators opt in, and the claim that "the server stays unchanged" holds only for the code, not for its configuration.

The recommended end state combines them. Generate a P-256 key pair and an auth secret on the device, kept in a keychain group shared with an extension. Register kind `relay` with `keys` where the server offers `relay`, and kind `webpush` with the same relay URL and keys where it offers only `webpush`. The relay forwards the encrypted body unread, as an APNs alert with `mutable-content: 1` and the ciphertext in base64. A Notification Service Extension decrypts it with CryptoKit (P-256 ECDH, HKDF, AES-128-GCM), drops a payload whose `push_id` it does not know, and writes the title, body, thread and badge. The relay then sees no message content, and one relay serves both kinds.

Ladle ships step 1 without `keys` first because it works with nothing more than the relay above. The extension needs its own App ID, an App Group or keychain group, and a provisioning profile, which are more portal steps, and the relay has to exist first in either design. Moving to encrypted pushes later changes the relay's forwarding and adds the extension. Registration on the Apron side stays the same apart from `keys`.

## What aprond supports, and what is missing

apron-server-rust already implements kind `relay` (`src/server/push.rs`, `push_delivery.rs`; docs/DEVIATIONS.md, "Push kind relay and the badge scope"). It advertises `server.push.relay` and the `badge` scope. It posts JSON, or `aes128gcm` with `keys`, with `TTL`, `Urgency` and the bearer token. It waits `--push.delay` (default 30 s) and pushes only to users who are still away, and it removes a registration whose relay answers 404 or 410.

Missing:

- **The relay itself.** Nothing in the repositories posts to APNs.
- **The relay's host in `--push.hosts`.** `deploy/compose.yaml` passes no `--push.hosts`, so aprond accepts only the browsers' push services and refuses Ladle's registration with `invalid_params`. Add `--push.hosts=<relay host>`. Listing a host replaces the default, so list the browser services too if apron-web's web push should keep working: `--push.hosts=fcm.googleapis.com --push.hosts=*.push.services.mozilla.com --push.hosts=web.push.apple.com --push.hosts=*.push.apple.com --push.hosts=*.notify.windows.com --push.hosts=<relay host>`.

## Steps for the owner

Do these in order. Ladle stays without push until step 6.

1. **Enable Push Notifications on the App ID.** In the Apple Developer portal, go to Certificates, Identifiers & Profiles > Identifiers > `app.ladle.ios` and turn on Push Notifications. Save. Automatic signing picks this up in the next provisioning profile.
2. **Create the APNs key.** In Certificates, Identifiers & Profiles > Keys, add a key with Apple Push Notifications service (APNs) enabled, for both sandbox and production. Download the `.p8` file once and keep it safe. Note its Key ID and the Team ID (`MP92RCAPRG`).
3. **Run the relay.** Deploy a service that does what "What the relay does" says, at a name such as `push.<your domain>`, with the `.p8`, Key ID and Team ID as secrets. Use the sandbox APNs host for builds run from Xcode (`LADLE_PUSH = development`) and the production host for TestFlight and App Store builds (`LADLE_PUSH = production`). A relay can choose by the `environment` each device registered with.
4. **Allow the relay on each server.** On aprond, add the `--push.hosts` list above to `deploy/compose.yaml` and redeploy. Check that the server frame lists `"push": {"relay": {}, …}`.
5. **Turn push on in the build.** In the gitignored `Config/Domains.xcconfig`, set `LADLE_PUSH = development`, or `production` for an archive bound for TestFlight. `./build.sh` runs `scripts/associated-domains.sh`, which adds `aps-environment` to the entitlements. Without step 1 automatic signing fails, which is why this stays empty until then.
6. **Turn it on in Ladle.** In Preferences > Notifications, set Push Relay to the relay's https address and turn Notifications on. Each server's Notify Me About footer then says "Alerts even when Ladle is closed", or the server's reason for refusing.

## Checking it

- `PushIntegrationTests` (ApronKit) runs aprond with a loopback relay. Ladle registers, goes away, and a mention reaches the relay as the §4.9.3 payload with the bearer token. Run it with `APROND=<binary> APRON_REQUIRE_SERVER=1 swift test --package-path Packages/ApronKit --filter PushIntegrationTests`.
- On a device: sign in, close Ladle, and have someone mention you. The alert comes after `--push.delay`. Tap it, and Ladle opens at the message.
