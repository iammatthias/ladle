import ApronKit
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file on the draft: being fitted to the server, then ready to send.
struct DraftAttachment: Identifiable {
    enum Phase {
        case preparing
        case ready(Attachment)
    }

    let id = UUID()
    var name: String
    var phase: Phase

    var attachment: Attachment? {
        if case .ready(let attachment) = phase { return attachment }
        return nil
    }
}

/// Where picked files wait before they are sent: an app-private folder in the temporary
/// directory. The outbox lives in memory, so nothing outlives a launch; `clear()` runs at start.
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

    /// Fits a picked file to the server off the main thread (`AttachmentPreparer`). A
    /// security-scoped URL from the document picker stays open while it is copied.
    static func prepare(_ source: URL, name: String, contentType: String?, limits: MediaLimits.Category?) async throws -> Attachment {
        try await Task.detached(priority: .userInitiated) {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            return try AttachmentPreparer.prepare(source, title: name, contentType: contentType, limits: limits, into: directory)
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

/// The web's Attachments: the draft's files above the composer, each removable.
struct AttachmentTray: View {
    let attachments: [DraftAttachment]
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: Tokens.Space.s3) {
                ForEach(attachments) { item in
                    AttachmentTile(item: item) { remove(item.id) }
                }
            }
            .padding(.horizontal, Tokens.Space.s4)
            .padding(.top, Tokens.Space.s3)
            .padding(.bottom, Tokens.Space.s1)
        }
        .accessibilityLabel("Files to send")
    }
}

/// The web's AttachmentTile: a 96 pt picture for an image, a file card for anything else, with
/// the name and the size it goes out at ("Preparing…" while an image shrinks), and an (x).
struct AttachmentTile: View {
    let item: DraftAttachment
    let remove: () -> Void

    var body: some View {
        let attachment = item.attachment
        Group {
            if let attachment, attachment.isImage {
                RemoteImage(url: attachment.fileURL, maxPixel: 400)
                    .frame(width: thumbWidth(attachment), height: 96)
                    .overlay(alignment: .bottom) { label(attachment).background(Palette.timeline.opacity(0.88)) }
            } else {
                HStack(spacing: Tokens.Space.s2) {
                    FileGlyph(symbol: attachment.map(symbol) ?? "doc")
                    label(attachment)
                }
                .padding(Tokens.Space.s2)
                .frame(width: 200, height: 96, alignment: .leading)
            }
        }
        .background(Palette.raised)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(Palette.line))
        .overlay(alignment: .topTrailing) {
            Button("Remove \(item.name)", systemImage: "xmark", action: remove)
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
        .padding(.top, Tokens.Space.s1)
        .padding(.trailing, Tokens.Space.s1)
        .accessibilityElement(children: .contain)
    }

    private func label(_ attachment: Attachment?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(attachment?.title ?? item.name).fontWeight(.semibold).foregroundStyle(Palette.ink)
                .lineLimit(1).truncationMode(.middle)
            Text(attachment.map { ByteCountFormatter.string(fromByteCount: Int64($0.byteCount), countStyle: .file) } ?? "Preparing…")
                .foregroundStyle(Palette.inkMuted)
        }
        .apText(.xs)
        .padding(.horizontal, Tokens.Space.s2)
        .padding(.vertical, Tokens.Space.s1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func thumbWidth(_ attachment: Attachment) -> CGFloat {
        guard let width = attachment.pixelWidth, let height = attachment.pixelHeight, height > 0 else { return 96 }
        return min(200, max(96, 96 * CGFloat(width) / CGFloat(height)))
    }

    private func symbol(_ attachment: Attachment) -> String {
        if attachment.isVideo { return "film" }
        if attachment.isAudio { return "waveform" }
        return FileCard.symbol(for: attachment.title)
    }
}

/// The system camera for a photo or a video, where the device has one.
struct CameraPicker: UIViewControllerRepresentable {
    let took: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
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
