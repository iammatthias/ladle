import ApronKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// JSON Lines, an Apron export's form (ARCHIVE.md §1), as `project.yml` declares it.
    static let jsonLines = UTType(importedAs: "org.jsonlines.jsonl", conformingTo: .text)
}

/// An export to read: the file read, or why it couldn't be.
struct OpenedExport: Identifiable {
    let id = UUID()
    let result: Result<Archive, ArchiveError>

    /// Reads a file picked or handed to the app. A file another app opened in is copied into the
    /// app's Inbox, which goes once it is read.
    init(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text = (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
        if url.path().contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        do throws(ArchiveError) {
            guard let text else { throw .notAnArchive }
            result = .success(try Archive(text: text))
        } catch {
            result = .failure(error)
        }
    }

    init(archive: Archive) { result = .success(archive) }
}

/// An export, read-only, as apron-web's `/archive`: it first asks whether its images may load
/// from the sites it names, then reads it through an `ArchiveServer` as it would a server, its
/// rooms and threads in a list and each one's timeline, with what the export is in the
/// composer's place.
struct ArchiveViewer: View {
    let opened: OpenedExport
    /// The viewer's media choices, whose blocked sites hold in an export too.
    let mediaSettings: MediaSettings
    @State private var session: ServerSession?
    @State private var asked = false
    /// The rooms open in the viewer, and a link's place in the one on top.
    @State private var path: [String] = []
    @State private var place: ApronLink?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch opened.result {
                case .failure(let error):
                    EmptyState(title: "Can’t Read This File", detail: error.description) { EmptyView() }
                case .success(let archive):
                    if let session {
                        ArchiveRooms(session: session, place: $place)
                    } else if !archive.mediaHosts.isEmpty, !asked {
                        askImages(archive)
                    } else {
                        ProgressView().task { open(archive, withImages: false) }
                    }
                }
            }
            .background(Palette.chrome)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        // Nothing loads from a site the reader didn't agree to, link previews included.
        .environment(\.fetchesLinkPreviews, false)
        // A link into the export, such as a search result or a room chip, opens here: the app's
        // routing knows no server at the export's address.
        .environment(\.openURL, OpenURLAction { url in
            guard let link = ApronLink(url) else { return .systemAction }
            guard let room = link.room, link.server.map({ $0.host() == ServerSession.archiveURL.host() }) ?? true else { return .discarded }
            if path.last != room { path.append(room) }
            place = link
            return .handled
        })
        .onDisappear { Task { await session?.stop() } }
    }

    /// apron-web's "Load its images?": a file says what it likes, so nothing loads from the sites
    /// it names unasked.
    private func askImages(_ archive: Archive) -> some View {
        let hosts = archive.mediaHosts
        return VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            Text("Load its images?").apText(.title, .semibold).foregroundStyle(Palette.ink)
            Text("This export’s images load from \(hosts.joined(separator: ", ")). Loading them lets \(hosts.count == 1 ? "that site" : "those sites") see that you’re reading it. Nothing loads from any other site: without them, images show as links and avatars as initials.")
                .apText(.body).foregroundStyle(Palette.inkMuted)
            HStack {
                Button("Open Without Images") { open(archive, withImages: false) }.buttonStyle(.bordered)
                Spacer()
                Button("Load Images") { open(archive, withImages: true) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(Tokens.Space.s6)
        .frame(maxWidth: 520, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Open an Export")
    }

    private func open(_ archive: Archive, withImages: Bool) {
        asked = true
        guard session == nil else { return }
        let reader = ServerSession.reading(archive, withImages: withImages, mediaSettings: mediaSettings)
        session = reader
        reader.start()
        Task {
            for _ in 0 ..< 200 where reader.status != .signedOut { try? await Task.sleep(for: .milliseconds(10)) }
            _ = try? await reader.signIn(.guest(name: nil))
        }
    }
}

/// An export's rooms and threads, each opening its timeline.
private struct ArchiveRooms: View {
    let session: ServerSession
    @Binding var place: ApronLink?
    @State private var reminders = Reminders(store: InMemoryReminderStore(), notifier: SilentReminderNotifier())
    @State private var hidden = HiddenDescriptions()
    @State private var drafts = Drafts()

    var body: some View {
        List {
            if let note = session.archiveNote {
                Text(note).apText(.sm).foregroundStyle(Palette.inkMuted).listRowBackground(Color.clear)
            }
            ForEach(session.roomTree) { node in
                link(node.roomID, thread: false)
                ForEach(node.threadIDs, id: \.self) { link($0, thread: true) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle(session.serverName)
        .navigationDestination(for: String.self) { roomID in
            TimelineView(session: session, roomID: roomID, reminders: reminders, hidden: hidden, drafts: drafts, place: $place)
        }
        .overlay { if session.status != .signedIn { ProgressView() } }
    }

    private func link(_ roomID: String, thread: Bool) -> some View {
        NavigationLink(value: roomID) {
            HStack(spacing: Tokens.Space.s2) {
                if session.isPrivate(roomID) { Lock(tint: Palette.private) }
                Text(session.title(of: roomID)).apText(.body).foregroundStyle(Palette.ink)
            }
            .padding(.leading, thread ? Tokens.Space.s6 : 0)
        }
        .listRowBackground(Color.clear)
    }
}
