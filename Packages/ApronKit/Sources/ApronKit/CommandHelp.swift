import Foundation

/// One command a server offers (§4.1), as its `/help` lists it.
public struct ServerCommand: Hashable, Sendable {
    /// The command word without its slash, such as `invite-device`.
    public var name: String
    /// How to write it, such as `/invite-device add|remove [<id>]`.
    public var usage: String
    /// What it does.
    public var summary: String
}

/// The commands a server's `/help` lists for this user. No server describes its commands in the
/// `server` frame; apron-server-cloudflare and apron-server-rust answer `/help` with a `~private`
/// markdown notice holding one line per command the user may run, `` - `<usage>`: <summary> ``.
/// This is the one reader of that text, so a structured form (shazow/apron#85) can replace it here.
public struct CommandHelp: Hashable, Sendable {
    public var commands: [ServerCommand]

    /// The list in a `~private` notice, or nil for any other notice.
    public init?(notice: Notice) {
        guard notice.from.userID == "~private", let text = notice.body?["text"]?.stringValue else { return nil }
        self.init(text: text)
    }

    /// The list in a `/help` text, or nil unless every line is one command.
    public init?(text: String) {
        var commands: [ServerCommand] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let command = Self.command(in: line) else { return nil }
            commands.append(command)
        }
        guard !commands.isEmpty else { return nil }
        self.commands = commands
    }

    /// `` - `/name args`: summary ``
    private static func command(in line: String) -> ServerCommand? {
        guard line.hasPrefix("- `/") else { return nil }
        let rest = line.dropFirst(2)
        guard let close = rest.dropFirst().firstIndex(of: "`") else { return nil }
        let usage = String(rest[rest.index(after: rest.startIndex) ..< close])
        let after = rest[rest.index(after: close)...]
        guard after.hasPrefix(":") else { return nil }
        let summary = after.dropFirst().trimmingCharacters(in: .whitespaces)
        let name = usage.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        guard !name.isEmpty, !summary.isEmpty else { return nil }
        return ServerCommand(name: name, usage: usage, summary: summary)
    }

    /// The commands whose name starts with `query`, in the server's order.
    public func matching(_ query: String) -> [ServerCommand] {
        let query = query.lowercased()
        return commands.filter { $0.name.hasPrefix(query) }
    }

    /// The command word being typed: composer text that starts with `/`, not `//` (§4.1's
    /// escape), before any space or line break.
    public static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/"), !draft.hasPrefix("//"), !draft.contains(where: \.isWhitespace) else { return nil }
        return String(draft.dropFirst())
    }
}
