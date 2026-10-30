@testable import ApronKit
import XCTest

final class CommandHelpTests: XCTestCase {
    /// apron-server-cloudflare's `/help` for an admin with uploads on and emoji configured: its
    /// COMMANDS table (src/index.ts at fdf410d, alphabetical) as `handleCommand` writes it, the
    /// admins' marked "(admin-only)", with MAX_JOIN_USES 50.
    static let cloudflareAdmin = """
    - `/admin [remove] <user_id>`: make a registered user an admin, or no longer one (admin-only)
    - `/avatar`: set your avatar: send this command with one image attached
    - `/emoji add|remove :name:`: add a custom emoji, or replace its image: send /emoji add :name: with one image attached; /emoji remove :name: removes it
    - `/help`: list the commands you can use here
    - `/invite-bot`: get a sign-in token for your bot; a new one replaces the last
    - `/invite-code <uses>`: get a token that signs up to <uses> new users (at most 50) for a week, replacing the last one; /invite-code 0 revokes it (admin-only)
    - `/invite-device list|add|remove [<id>]`: list, get or revoke tokens that sign in as you on another device
    - `/invite-purge <user_id>`: sign a user out everywhere, remove their passkeys and tokens, and get a new token for them (admin-only)
    - `/invite-token <user_id>`: create a user who signs in with a token instead of a passkey, and get the token (admin-only)
    - `/kick <user_id>`: remove a user from this room (admin-only)
    - `/passkeys [remove <n>]`: list your account's passkeys, or remove one of them
    - `/purge <user_id>`: disconnect a user and delete their account, bot, and everything they posted or uploaded (admin-only)
    - `/rename <old_user_id> <new_user_id>`: change a registered user's user_id (admin-only)
    - `/role <user_id> [<role>]`: show a user's roles, or give or take away one (admin, mod, threader and bot act as such; friend, like any role, raises their posting limits, and admin, mod and friend may use /emoji) (admin-only)
    - `/server [title|description [<text>] | avatar]`: show this server's title, description and avatar; set one, the avatar with one image attached; or clear one, back to the deployment's (admin-only)
    - `/status`: show today's Cloudflare usage and the demo's budgets (admin-only)
    - `/toggle <activity|uploads|presence|addmember>`: turn typing activity, uploads, user status (presence), or users adding others to rooms (addmember) off or on for everyone (admin-only)
    """

    /// apron-server-rust's `/help` for an account with no roles while uploads are on
    /// (SERVER_COMMANDS in src/server/commands.rs, filtered by `Audience::lists`).
    static let rustAccount = """
    - `/avatar`: with one image attached: set your avatar
    - `/help`: list the commands you can use here
    - `/invite-bot`: get a token that signs in as your bot, named after you; again, it replaces the token and renames the bot
    - `/invite-device list|add|remove [<id>]`: list, get or revoke tokens that sign in as you on another device
    - `/passkeys [remove <n>]`: list your account's passkeys, or remove one of them
    """

    /// Both servers' `/help` for a guest, read-only or not.
    static let guest = "- `/help`: list the commands you can use here"

    func testCloudflaresAdminListParsesEveryLine() throws {
        let help = try XCTUnwrap(CommandHelp(text: Self.cloudflareAdmin))
        XCTAssertEqual(help.commands.map(\.name), [
            "admin", "avatar", "emoji", "help", "invite-bot", "invite-code", "invite-device", "invite-purge", "invite-token",
            "kick", "passkeys", "purge", "rename", "role", "server", "status", "toggle",
        ])
        XCTAssertEqual(help.commands[2], ServerCommand(
            name: "emoji", usage: "/emoji add|remove :name:",
            summary: "add a custom emoji, or replace its image: send /emoji add :name: with one image attached; /emoji remove :name: removes it"))
        XCTAssertEqual(help.commands[1].summary, "set your avatar: send this command with one image attached")
    }

    func testRustsAccountListParsesEveryLine() throws {
        let help = try XCTUnwrap(CommandHelp(text: Self.rustAccount))
        XCTAssertEqual(help.commands.map(\.usage), ["/avatar", "/help", "/invite-bot", "/invite-device list|add|remove [<id>]", "/passkeys [remove <n>]"])
        XCTAssertEqual(help.commands[0].summary, "with one image attached: set your avatar")
    }

    func testAGuestGetsOnlyHelp() throws {
        let help = try XCTUnwrap(CommandHelp(text: Self.guest))
        XCTAssertEqual(help.commands, [ServerCommand(name: "help", usage: "/help", summary: "list the commands you can use here")])
    }

    func testOtherNoticesAreNoList() {
        XCTAssertNil(CommandHelp(text: "Uploads are now **on**."))
        XCTAssertNil(CommandHelp(text: "Slow down: you can send 5 messages a minute here."))
        XCTAssertNil(CommandHelp(text: Self.guest + "\n\nOr open this link on **phone**: <https://link.apron.chat/>"))
        XCTAssertNil(CommandHelp(text: "- `token`: copy this"))
        XCTAssertNil(CommandHelp(text: ""))
    }

    func testOnlyAPrivateNoticeCarriesTheList() throws {
        let body: JSONValue = ["text": .string(Self.guest), "format": "markdown"]
        let fromServer = Notice(roomID: "general", from: try XCTUnwrap(UserObject(["user_id": "~private", "name": "System message to you"])), body: body)
        let fromSomeone = Notice(roomID: "general", from: try XCTUnwrap(UserObject(["user_id": "~mallory", "name": "Mallory"])), body: body)
        XCTAssertEqual(CommandHelp(notice: fromServer)?.commands.map(\.name), ["help"])
        XCTAssertNil(CommandHelp(notice: fromSomeone))
    }

    func testMatchingIsByNamePrefixInTheServersOrder() throws {
        let help = try XCTUnwrap(CommandHelp(text: Self.cloudflareAdmin))
        XCTAssertEqual(help.matching("inv").map(\.name), ["invite-bot", "invite-code", "invite-device", "invite-purge", "invite-token"])
        XCTAssertEqual(help.matching("PU").map(\.name), ["purge"])
        XCTAssertEqual(help.matching("").count, 17)
        XCTAssertEqual(help.matching("x"), [])
    }

    func testTheQueryIsTheWordAfterALeadingSlashUntilASpace() {
        XCTAssertEqual(CommandHelp.query(in: "/"), "")
        XCTAssertEqual(CommandHelp.query(in: "/inv"), "inv")
        XCTAssertNil(CommandHelp.query(in: "/invite-device add phone"))
        XCTAssertNil(CommandHelp.query(in: "/help\n"))
        XCTAssertNil(CommandHelp.query(in: "//shrug"))
        XCTAssertNil(CommandHelp.query(in: "hi /help"))
    }
}
