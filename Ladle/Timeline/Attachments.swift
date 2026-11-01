import ApronKit
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Where picked files land before they are fitted to the server: an app-private folder in the
/// temporary directory, cleared at launch. A fitted file goes into the drafts' staging folder
/// (`Drafts.staging`), which keeps it while its draft does, across launches.
enum AttachmentStaging {
    static let directory = URL.temporaryDirectory.appending(path: "Attachments", directoryHint: .isDirectory)
    static let imports = directory.appending(path: "Imports", directoryHint: .isDirectory)

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A fresh folder for one picked file, so two files of one name never collide.
    static func importFolder() throws -> URL {
        let folder = imports.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Fits a picked file to the server off the main thread, as its `UploadPlan` says: a sound
    /// or video is re-encoded here first (`MediaCompression`), and `AttachmentPreparer` does the
    /// rest, into `staging`. A security-scoped URL from the document picker stays open while it
    /// is read.
    static func prepare(_ source: URL, name: String, contentType: String?, limits: MediaLimits.Category?,
                        into staging: URL) async throws -> Attachment {
        try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let base = (name as NSString).deletingPathExtension
            let reencoded: URL
            switch try AttachmentPreparer.plan(for: source, declared: contentType, limits: limits).plan {
            case .audio(let maxBytes):
                reencoded = try MediaCompression.audio(source, maxBytes: maxBytes, named: base + ".m4a", into: importFolder())
            case .video(let type, let maxBytes):
                let name = base + (type == "video/mp4" ? ".mp4" : ".mov")
                reencoded = try await MediaCompression.video(source, type: type, maxBytes: maxBytes, named: name, into: importFolder())
            default:
                return try AttachmentPreparer.prepare(source, title: name, contentType: contentType, limits: limits, into: staging)
            }
            return try AttachmentPreparer.prepare(reencoded, title: reencoded.lastPathComponent, limits: limits, into: staging)
        }.value
    }
}

/// A file received from Photos, a drop or a paste, copied into staging under its own name.
struct ImportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try ImportedFile(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try ImportedFile(copying: $0.file) }
        FileRepresentation(importedContentType: .item) { try ImportedFile(copying: $0.file) }
    }

    init(copying file: URL) throws {
        let destination = try AttachmentStaging.importFolder().appending(path: file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        url = destination
    }

    init(url: URL) {
        self.url = url
    }
}

/// The web's Attachments: tiles in a row that scrolls sideways, above the composer.
struct AttachmentTray<Tiles: View>: View {
    let label: String
    @ViewBuilder let tiles: Tiles

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: Tokens.Space.s3) { tiles }
                .padding(.horizontal, Tokens.Space.s4)
                .padding(.top, Tokens.Space.s3)
                .padding(.bottom, Tokens.Space.s1)
        }
        .accessibilityLabel(label)
    }
}

extension AttachmentTray {
    /// The draft's files, each renamed or taken off in place.
    init(files: Binding<[StagedFile]>) where Tiles == ForEach<[StagedFile], UUID, AttachmentTile> {
        self.init(label: "Files to send") {
            ForEach(files.wrappedValue) { item in
                AttachmentTile(name: item.shownName, detail: StagedPreview.detail(item), preview: StagedPreview.of(item),
                               rename: { name in
                                   if let index = files.wrappedValue.firstIndex(where: { $0.id == item.id }) { files.wrappedValue[index].rename(to: name) }
                               },
                               remove: { files.wrappedValue.removeAll { $0.id == item.id } })
            }
        }
    }
}

/// What a tile shows of its file.
enum TilePreview: Hashable {
    /// A picture at its width over its height.
    case image(URL, aspect: CGFloat?)
    case glyph(String)
}

/// A staged file's tile: the file as fitted, its size, or "Preparing…".
enum StagedPreview {
    static func of(_ item: StagedFile) -> TilePreview {
        guard let attachment = item.attachment else { return .glyph("doc") }
        if attachment.isImage {
            let aspect = attachment.pixelWidth.flatMap { width in attachment.pixelHeight.map { CGFloat(width) / CGFloat(max($0, 1)) } }
            return .image(attachment.fileURL, aspect: aspect)
        }
        if attachment.isVideo { return .glyph("film") }
        if attachment.isAudio { return .glyph("waveform") }
        return .glyph(FileCard.symbol(for: attachment.title))
    }

    static func detail(_ item: StagedFile) -> String {
        item.attachment.map { ByteCountFormatter.string(fromByteCount: Int64($0.byteCount), countStyle: .file) } ?? "Preparing…"
    }
}

/// The web's AttachmentTile, for a file on a draft or an embed in the message editor: a 96 pt
/// picture for an image, a file card for anything else, with its name and a detail under it,
/// and an (x). A renamable tile's name is a button that opens it for typing in place: Return or
/// leaving the field keeps the new name, Escape the old one, and an empty name changes nothing.
struct AttachmentTile: View {
    let name: String
    let detail: String
    let preview: TilePreview
    var rename: ((String) -> Void)?
    var remove: (() -> Void)?
    @State private var renaming = false
    @State private var typed = ""
    @FocusState private var typing: Bool
    @Environment(\.shotPins) private var shotPins

    var body: some View {
        Group {
            switch preview {
            case .image(let url, let aspect):
                RemoteImage(url: url, maxPixel: 400)
                    .frame(width: min(200, max(120, 96 * (aspect ?? 1))), height: 96)
                    .overlay(alignment: .bottom) { label.background(Palette.timeline.opacity(0.88)) }
            case .glyph(let symbol):
                HStack(spacing: Tokens.Space.s2) {
                    FileGlyph(symbol: symbol)
                    label
                }
                .padding(Tokens.Space.s2)
                .frame(width: 200, height: 96, alignment: .leading)
            }
        }
        .background(Palette.raised)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(renaming ? Palette.accent : Palette.line))
        .overlay(alignment: .topTrailing) {
            if let remove, !renaming {
                Button("Remove \(name)", systemImage: "xmark", action: remove)
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Palette.ink)
                    .frame(width: 24, height: 24)
                    .background(Palette.raised, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.line))
                    .frame(width: Tokens.Size.touchTarget, height: Tokens.Size.touchTarget)
                    .contentShape(Rectangle())
                    .offset(x: 10, y: -10)
            }
        }
        .padding(.top, Tokens.Space.s1)
        .padding(.trailing, Tokens.Space.s1)
        .accessibilityElement(children: .contain)
        .contextMenu {
            if rename != nil { Button("Rename", systemImage: "pencil") { startRenaming() } }
            if let remove { Button("Remove", systemImage: "xmark", role: .destructive, action: remove) }
        }
        .onAppear { if shotPins.renaming == name, rename != nil { startRenaming() } }
    }

    @ViewBuilder
    private var label: some View {
        VStack(alignment: .leading, spacing: 0) {
            if renaming {
                TextField("File name", text: $typed)
                    .fontWeight(.semibold)
                    .foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($typing)
                    .onSubmit { finish(keep: true) }
                    .onKeyPress(.escape) {
                        finish(keep: false)
                        return .handled
                    }
                    .onChange(of: typing) { if !typing { finish(keep: true) } }
            } else if rename != nil {
                Button(action: startRenaming) {
                    VStack(alignment: .leading, spacing: 0) {
                        title
                        HStack(spacing: Tokens.Space.s1) {
                            Text(detail).lineLimit(1)
                            Image(systemName: "pencil").imageScale(.small)
                        }
                        .foregroundStyle(Palette.inkMuted)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename \(name)")
                .accessibilityValue(detail)
            } else {
                title
                Text(detail).foregroundStyle(Palette.inkMuted)
            }
        }
        .apText(.xs)
        .padding(.horizontal, Tokens.Space.s2)
        .padding(.vertical, Tokens.Space.s1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        Text(name).fontWeight(.semibold).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
    }

    private func startRenaming() {
        typed = name
        renaming = true
        typing = true
    }

    private func finish(keep: Bool) {
        guard renaming else { return }
        renaming = false
        let next = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if keep, !next.isEmpty, next != name { rename?(next) }
    }
}

/// The system camera for a photo, or a video where the server takes videos, on a device with one.
struct CameraPicker: UIViewControllerRepresentable {
    var videos = true
    let took: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier] + (videos ? [UTType.movie.identifier] : [])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
            if let movie = info[.mediaURL] as? URL, let imported = try? ImportedFile(copying: movie) {
                parent.took(imported.url)
            } else if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9),
                      let folder = try? AttachmentStaging.importFolder() {
                let file = folder.appending(path: "Photo \(stamp).jpg")
                if (try? data.write(to: file)) != nil { parent.took(file) }
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
