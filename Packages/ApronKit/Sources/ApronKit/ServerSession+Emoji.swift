import Foundation

/// Custom emoji (EXTENSIONS.md, `ext:emoji`): the catalog is fetched the first time something
/// needs it (a key shown, the picker or the `:` list opened) and kept for as long as the server's
/// `catalog_url` stays the same. A fetch that fails is not tried again until the URL changes.
/// Until a catalog arrives, keys show as they would without the extension.
extension ServerSession {
    /// The current `catalog_url`'s catalog, once fetched.
    public var emojiCatalog: EmojiCatalog? {
        server?.emojiCatalogURL.flatMap { emojiCatalogs[$0] }
    }

    /// Fetches the current catalog unless it was asked for already. Returns when it has arrived,
    /// failed, or was asked for earlier.
    public func loadEmojiCatalog() async {
        guard let url = server?.emojiCatalogURL, !emojiCatalogsAsked.contains(url) else { return }
        emojiCatalogsAsked.insert(url)
        let policy = mediaPolicy
        guard let data = try? await environment.fetchEmojiCatalog(url), let json = try? JSONValue(parsing: data) else { return }
        emojiCatalogs[url] = EmojiCatalog(json: json, policy: policy)
    }
}
