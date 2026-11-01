import Foundation
import Observation
import Synchronization

/// The room or thread a draft is written in, on one saved server. A thread is a room of its own,
/// so it keeps its own draft, as apron-web keys its drafts by server and `room_id`.
public struct DraftKey: Hashable, Sendable {
    public var server: UUID
    public var roomID: String

    public init(server: UUID, roomID: String) {
        self.server = server
        self.roomID = roomID
    }
}

/// A file on a draft: being fitted to the server, then ready to send (§4.8.4).
public struct StagedFile: Identifiable, Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case preparing
        case ready(Attachment)
    }

    public let id: UUID
    public var name: String
    public var phase: Phase

    public init(id: UUID = UUID(), name: String, phase: Phase) {
        self.id = id
        self.name = name
        self.phase = phase
    }

    public var attachment: Attachment? {
        if case .ready(let attachment) = phase { return attachment }
        return nil
    }
}

/// What the composer holds in one room, as apron-web's `PaneDrafts` keeps it: the text and its
/// mentions, the message it replies to, and the staged files. An edit is never kept: apron-web
/// closes its editor when the pane changes, and the draft waits beside it.
public struct ComposerDraft: Hashable, Sendable {
    public var field: DraftField
    public var files: [StagedFile]
    /// The link previews taken off this draft, by URL (`PreviewLink.url`): the message goes out
    /// without them. Given back with a failed command's draft, as apron-web's `composerDismissed`,
    /// and never kept across launches.
    public var dismissedPreviews: [String]

    public init(field: DraftField = DraftField(), files: [StagedFile] = [], dismissedPreviews: [String] = []) {
        self.field = field
        self.files = files
        self.dismissedPreviews = dismissedPreviews
    }

    public var isEmpty: Bool { field.text.isEmpty && field.replyTo == nil && files.isEmpty }

    /// Puts a file's fitted form in place of its tile, if the draft still holds it.
    public mutating func ready(_ id: StagedFile.ID, as attachment: Attachment) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        files[index].phase = .ready(attachment)
    }
}

/// Every room's draft on this device, kept across launches where apron-web asks before a reload
/// would lose one: iOS ends an app without asking. A file is kept once it is ready; one still
/// being fitted when the app ends is gone, with the work it needed. Staged files live under
/// `staging`, which `pruneStaging()` sweeps of files no draft holds, such as those already sent.
@MainActor
@Observable
public final class Drafts {
    public private(set) var byKey: [DraftKey: ComposerDraft]
    /// Where ready files are kept while a draft holds them.
    public let staging: URL
    @ObservationIgnored private let store: any DraftStore

    public init(store: any DraftStore, staging: URL) {
        self.store = store
        self.staging = staging
        byKey = store.load(staging: staging)
    }

    /// A draft that is only in memory, with its files in a fresh temporary folder: for tests,
    /// previews and the renderer.
    public convenience init(_ drafts: [DraftKey: ComposerDraft] = [:]) {
        self.init(store: InMemoryDraftStore(drafts), staging: URL.temporaryDirectory.appending(path: "Staged-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    /// The draft for `key`, empty when none is kept. Setting an empty one forgets it.
    public subscript(key: DraftKey) -> ComposerDraft {
        get { byKey[key] ?? ComposerDraft() }
        set {
            guard byKey[key] ?? ComposerDraft() != newValue else { return }
            let kept = KeptDraft(byKey[key]), next = KeptDraft(newValue)
            byKey[key] = newValue.isEmpty ? nil : newValue
            if kept != next { store.save(byKey, staging: staging) }
        }
    }

    /// Gives a failed command's draft back to `key`, as apron-web's `PaneDrafts.restore`, unless
    /// something has been typed, replied to or attached there since. Returns whether it did.
    @discardableResult
    public func restore(_ draft: ComposerDraft, at key: DraftKey) -> Bool {
        guard self[key].isEmpty else { return false }
        self[key] = draft
        return true
    }

    /// Forgets every draft on a server, and their files, as when the server is removed.
    public func removeAll(server: UUID) {
        let gone = byKey.filter { $0.key.server == server }
        guard !gone.isEmpty else { return }
        for (key, draft) in gone {
            byKey[key] = nil
            for file in draft.files.compactMap(\.attachment) { try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent()) }
        }
        store.save(byKey, staging: staging)
    }

    /// Removes every folder under `staging` that holds no kept draft's file, and keeps the
    /// folder out of backups. Run at launch, before anything new is staged: a file sent or
    /// queued by the last launch is no longer needed, since the outbox does not outlive it.
    public func pruneStaging() {
        let manager = FileManager.default
        try? manager.createDirectory(at: staging, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var folder = staging
        try? folder.setResourceValues(values)
        let kept = Set(byKey.values.flatMap(\.files).compactMap { $0.attachment?.fileURL.deletingLastPathComponent().standardizedFileURL.path })
        for item in (try? manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        where !kept.contains(item.standardizedFileURL.path) {
            try? manager.removeItem(at: item)
        }
    }
}

/// Where drafts are kept on this device.
public protocol DraftStore: Sendable {
    /// Every kept draft. A file named relative to `staging` that is no longer there is left out.
    func load(staging: URL) -> [DraftKey: ComposerDraft]
    func save(_ drafts: [DraftKey: ComposerDraft], staging: URL)
}

/// `drafts.json` in the store's directory, beside `servers.json`:
/// `{server id: {room id: {text, mentions, reply_to, files}}}`, written whole and atomically.
/// A file's path is relative to the staging folder, since an app's container moves between
/// launches. A field that is missing or of the wrong kind takes its default, so older files keep
/// loading; a file that cannot be read is treated as empty, as apron-web treats blocked storage.
public struct FileDraftStore: DraftStore {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appending(path: "drafts.json")
    }

    public func load(staging: URL) -> [DraftKey: ComposerDraft] {
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([String: [String: KeptDraft]].self, from: data) else { return [:] }
        var drafts: [DraftKey: ComposerDraft] = [:]
        for (server, rooms) in all {
            guard let server = UUID(uuidString: server) else { continue }
            for (roomID, kept) in rooms {
                let draft = kept.draft(staging: staging)
                if !draft.isEmpty { drafts[DraftKey(server: server, roomID: roomID)] = draft }
            }
        }
        return drafts
    }

    public func save(_ drafts: [DraftKey: ComposerDraft], staging: URL) {
        var all: [String: [String: KeptDraft]] = [:]
        for (key, draft) in drafts {
            let kept = KeptDraft(draft, staging: staging)
            if !kept.isEmpty { all[key.server.uuidString, default: [:]][key.roomID] = kept }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(all) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// For tests and previews: keeps what was saved, files and all.
public final class InMemoryDraftStore: DraftStore {
    private let kept: Mutex<[DraftKey: ComposerDraft]>

    public init(_ drafts: [DraftKey: ComposerDraft] = [:]) { kept = Mutex(drafts) }

    public func load(staging: URL) -> [DraftKey: ComposerDraft] { kept.withLock { $0 } }
    public func save(_ drafts: [DraftKey: ComposerDraft], staging: URL) {
        kept.withLock { $0 = drafts.compactMapValues { draft in
            let ready = ComposerDraft(field: draft.field, files: draft.files.filter { $0.attachment != nil })
            return ready.isEmpty ? nil : ready
        } }
    }
}

/// A draft as `drafts.json` holds it: what outlives a launch.
struct KeptDraft: Codable, Hashable {
    var text = ""
    var mentions: [String: String] = [:]
    var replyTo: String?
    var files: [KeptFile] = []

    var isEmpty: Bool { text.isEmpty && replyTo == nil && files.isEmpty }

    /// The parts of `draft` that are kept; `staging` makes file paths relative, nil keeps them whole.
    init(_ draft: ComposerDraft?, staging: URL? = nil) {
        guard let draft else { return }
        text = draft.field.isEdit ? "" : draft.field.text
        mentions = draft.field.isEdit ? [:] : draft.field.mentions
        replyTo = draft.field.replyTo?.text
        files = draft.files.compactMap { file in file.attachment.map { KeptFile(file.name, $0, staging: staging) } }
    }

    func draft(staging: URL) -> ComposerDraft {
        let mode = replyTo.flatMap(LogID.init).map(DraftField.Mode.reply) ?? .new
        let staged = files.compactMap { $0.staged(staging: staging) }
        return ComposerDraft(field: DraftField(mode: mode, text: text, mentions: mentions), files: staged)
    }

    private enum CodingKeys: String, CodingKey {
        case text, mentions, files
        case replyTo = "reply_to"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = (try? container.decodeIfPresent(String.self, forKey: .text)) ?? ""
        mentions = (try? container.decodeIfPresent([String: String].self, forKey: .mentions)) ?? [:]
        replyTo = try? container.decodeIfPresent(String.self, forKey: .replyTo)
        files = ((try? container.decodeIfPresent([Lossy<KeptFile>].self, forKey: .files)) ?? []).compactMap(\.value)
    }
}

/// A ready file as `drafts.json` holds it.
struct KeptFile: Codable, Hashable {
    var name: String
    var path: String
    var title: String
    var contentType: String
    var byteCount: Int
    var pixelWidth: Int?
    var pixelHeight: Int?

    init(_ name: String, _ attachment: Attachment, staging: URL?) {
        self.name = name
        let full = attachment.fileURL.standardizedFileURL.path
        let base = staging.map { $0.standardizedFileURL.path + "/" }
        path = base.flatMap { full.hasPrefix($0) ? String(full.dropFirst($0.count)) : nil } ?? full
        title = attachment.title
        contentType = attachment.contentType
        byteCount = attachment.byteCount
        pixelWidth = attachment.pixelWidth
        pixelHeight = attachment.pixelHeight
    }

    /// The staged file, if it is still in the staging folder.
    func staged(staging: URL) -> StagedFile? {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        let url = staging.appending(path: path)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return StagedFile(name: name, phase: .ready(Attachment(fileURL: url, title: title, contentType: contentType, byteCount: byteCount,
                                                                 pixelWidth: pixelWidth, pixelHeight: pixelHeight)))
    }

    private enum CodingKeys: String, CodingKey {
        case name, path, title
        case contentType = "content_type"
        case byteCount = "byte_count"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
    }
}

/// One element of a list that decodes to nil instead of failing the list.
private struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
