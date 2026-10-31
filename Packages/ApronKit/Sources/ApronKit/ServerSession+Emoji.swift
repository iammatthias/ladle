import Foundation

/// Custom emoji (EXTENSIONS.md, `ext:emoji`): the catalog is fetched the first time something
/// needs it (a key shown, the picker or the `:` list opened) and kept for as long as the server's
/// `catalog_url` stays the same. A fetch that fails is not tried again until the URL changes.
/// Until a catalog arrives, keys show as they would without the extension.
extension ServerSession {
    /// The current `catalog_url`'s catalog, once fetched, with only the emoji the gate lets
    /// show: the rest stay their keys, and the picker leaves them out, as on the web.
    public var emojiCatalog: EmojiCatalog? {
        guard let url = server?.emojiCatalogURL, let catalog = emojiCatalogs[url] else { return nil }
        let gate = mediaGate
        if let kept = gatedEmojiCatalog, kept.url == url, kept.gate == gate { return kept.shown }
        let shown = catalog.gated(by: gate)
        gatedEmojiCatalog = (url, gate, shown)
        return shown
    }

    /// Fetches the current catalog unless it was asked for already, or the gate does not let
    /// it load (a fetch tells its site as much as an image does; inline, it loads from nowhere),
    /// in which case it is asked about again next time. Returns when it has arrived, failed, or
    /// was not fetched.
    public func loadEmojiCatalog() async {
        guard let url = server?.emojiCatalogURL, !emojiCatalogsAsked.contains(url) else { return }
        guard url.scheme?.lowercased() == "data" || mediaGate.allows(url, for: .avatar) else { return }
        emojiCatalogsAsked.insert(url)
        guard let data = try? await environment.fetchEmojiCatalog(url), let json = try? JSONValue(parsing: data) else { return }
        emojiCatalogs[url] = EmojiCatalog(json: json)
    }
}
