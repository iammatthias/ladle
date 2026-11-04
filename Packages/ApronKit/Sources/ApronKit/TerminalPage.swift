import Foundation

/// terminal.apron.chat's page for a `terminal` embed's live text (§4.8.6), as apron-web's
/// `terminalPageUrl` (#207): the stream on a page of its own, which reads it straight from the
/// chat server, as the embed does. Its keys go after the `#`, so the stream's address never
/// reaches that site's host:
///
/// https://terminal.apron.chat/#stream=https://chat.example/live/1&title=make%20test
///
/// The page reads only `https` streams without a user name or password, so there is no address
/// for any other. Opening it is a link the browser follows; the app reads nothing from it.
public enum TerminalPage {
    public static let origin = "https://terminal.apron.chat"

    /// `title` is the embed's; one that is empty once trimmed is left out.
    public static func url(stream: URL?, title: String? = nil) -> URL? {
        guard let stream, stream.scheme?.lowercased() == "https", stream.user == nil, stream.password == nil,
              var components = URLComponents(url: stream, resolvingAgainstBaseURL: false) else { return nil }
        components.fragment = nil
        guard let address = components.string else { return nil }
        var keys = ["stream=" + encode(address)]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { keys.append("title=" + encode(title)) }
        return URL(string: "\(origin)/#" + keys.joined(separator: "&"))
    }

    /// As the page writes its own links: `encodeURIComponent`, with `:` and `/` left readable.
    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: kept) ?? value
    }

    private static let kept = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'():/")
}
