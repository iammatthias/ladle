import ApronKit
import AVFoundation
import AVKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// An embed (§4.8) by kind: uploads as the web's EmbedUpload (a picture, a video tile, an audio
/// player or a file card, and a pending card while the file is written), everything else as
/// `EmbedCard`.
struct EmbedView: View {
    let session: ServerSession
    let embed: Embed
    /// The embed's place in the media viewer.
    let mediaID: String

    var body: some View {
        if let upload = embed.upload {
            UploadEmbedView(session: session, embed: embed, upload: upload, mediaID: mediaID)
        } else {
            EmbedCard(embed: embed, policy: session.mediaPolicy)
        }
    }
}

/// Media loads only under the server's `MediaPolicy`; anything else shows as a file card whose
/// link opens outside the app.
struct UploadEmbedView: View {
    let session: ServerSession
    let embed: Embed
    let upload: Upload
    let mediaID: String
    @Environment(\.openMedia) private var openMedia

    static let maxWidth: CGFloat = 320

    var body: some View {
        let policy = session.mediaPolicy
        let name = embed.name ?? "File"
        switch upload {
        case .pending:
            PendingUploadCard(name: name, progress: embed.embedID.flatMap { session.uploadProgress[$0] })
        case .image(let media) where policy.allowsMedia(media.url):
            Button { openMedia(mediaID) } label: {
                RemoteImage(url: media.url)
                    .aspectRatio(media.aspectRatio ?? 4 / 3, contentMode: .fit)
                    .frame(maxWidth: Self.maxWidth, maxHeight: Tokens.Size.embedMaxH, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
                    .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(Palette.line))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(media.alt ?? name)
            .accessibilityAddTraits(.isImage)
            .accessibilityHint("Opens the image full screen")
        case .video(let media) where policy.allowsMedia(media.url):
            VideoTile(url: media.url, name: name, aspect: media.aspectRatio)
        case .audio(let media) where policy.allowsMedia(media.url):
            AudioCard(url: media.url, name: name)
        default:
            FileCard(name: name, url: embed.url, loadable: embed.url.map(policy.allowsMedia) ?? false)
        }
    }
}

/// The web's pending upload: a dashed card with the file's name and, on the sender's side, how
/// much is written.
struct PendingUploadCard: View {
    let name: String
    let progress: Double?

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            FileGlyph(symbol: "arrow.up.doc", tint: Palette.inkMuted, ground: Palette.hover)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).apText(.ui, .semibold).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                Text(progress.map { "Uploading… \(Int(($0 * 100).rounded()))%" } ?? "Uploading…")
                    .apText(.sm).monospacedDigit().foregroundStyle(Palette.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.s3)
        .frame(minWidth: 260, maxWidth: Tokens.Size.embedMaxW, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(alignment: .bottom) {
            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Palette.hover
                        Palette.accent.frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .combine)
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
    }
}

/// The web's file glyph: a 36 pt rounded square, denim on denim-soft.
struct FileGlyph: View {
    var symbol = "doc"
    var tint = Palette.denim
    var ground = Palette.denimSoft

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(ground, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .accessibilityHidden(true)
    }
}

/// A file without a preview: its name and type. A tap downloads it into Quick Look, which
/// previews what iOS can and offers Share and Save for the rest. A file on another origin opens
/// in the browser instead.
struct FileCard: View {
    let name: String
    let url: URL?
    let loadable: Bool
    @State private var preview: URL?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        let card = HStack(spacing: Tokens.Space.s3) {
            ZStack {
                FileGlyph(symbol: Self.symbol(for: name))
                if loading { ProgressView().controlSize(.small) }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name).apText(.ui, .semibold).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                Text(failed ? "Couldn't download it" : Self.kind(of: name)).apText(.sm).foregroundStyle(failed ? Palette.danger : Palette.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.s3)
        .frame(minWidth: 260, maxWidth: Tokens.Size.embedMaxW, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
        if let url, loadable {
            Button { open(url) } label: { card }
                .buttonStyle(.plain)
                .quickLookPreview($preview)
                .accessibilityHint("Opens a preview")
        } else if let url {
            Link(destination: url) { card }.buttonStyle(.plain)
        } else {
            card
        }
    }

    private func open(_ url: URL) {
        guard !loading else { return }
        loading = true
        failed = false
        Task {
            defer { loading = false }
            do { preview = try await MediaLoader.shared.file(url, named: name) } catch { failed = true }
        }
    }

    static func type(of name: String) -> UTType? {
        UTType(filenameExtension: (name as NSString).pathExtension)
    }

    static func kind(of name: String) -> String {
        type(of: name)?.localizedDescription ?? "File"
    }

    static func symbol(for name: String) -> String {
        guard let type = type(of: name) else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .audiovisualContent) { return "film" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) { return "doc.text" }
        return "doc"
    }
}

/// A video in the system player, inline as the web's `<video>` (§4.8.4: `og.video`). The
/// player is made on first appearance and pauses when it scrolls away. With a `poster` (a link
/// card's `og.image`) nothing loads until the play button is tapped.
struct VideoTile: View {
    /// The picture shown before play: a hosted image, or one this device fetched.
    enum Poster {
        case remote(URL)
        case fetched(UIImage)
    }

    let url: URL
    let name: String
    let aspect: Double?
    var poster: Poster?
    /// Inside a link card, which clips and sizes it.
    var inCard = false
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if let player { VideoPlayer(player: player) }
            if player == nil, let poster {
                switch poster {
                case .remote(let url): RemoteImage(url: url).accessibilityHidden(true)
                case .fetched(let image): Image(uiImage: image).resizable().scaledToFill().accessibilityHidden(true)
                }
                Button("Play", systemImage: "play.fill", action: play)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Palette.onAccent)
                    .frame(width: 44, height: 44)
                    .background(Palette.accent, in: Circle())
                    .accessibilityLabel("Play video, \(name)")
            }
        }
        .aspectRatio(aspect ?? 16 / 9, contentMode: .fit)
        .frame(maxWidth: inCard ? .infinity : UploadEmbedView.maxWidth, maxHeight: inCard ? nil : Tokens.Size.embedMaxH, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: inCard ? 0 : Tokens.Radius.lg))
        .accessibilityLabel("Video, \(name)")
        .onAppear {
            if player == nil, poster == nil { player = AVPlayer(url: url) }
        }
        .onDisappear { player?.pause() }
    }

    private func play() {
        let made = AVPlayer(url: url)
        player = made
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        made.play()
    }
}

/// The web's audio card: the name and a player. One `AVPlayer`, made on first play.
struct AudioCard: View {
    let url: URL
    let name: String
    /// Fills the width it is given, inside a link card, instead of the upload width.
    var inCard = false
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var ended: (any NSObjectProtocol)?

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill", action: toggle)
                .labelStyle(.iconOnly)
                .foregroundStyle(Palette.onAccent)
                .frame(width: 36, height: 36)
                .background(Palette.accent, in: Circle())
                .touchTarget()
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Label(name, systemImage: "waveform").apText(.ui, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
                if let player {
                    SwiftUI.TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let duration = player.currentItem?.duration.seconds ?? .nan
                        let position = player.currentTime().seconds
                        HStack(spacing: Tokens.Space.s2) {
                            ProgressView(value: duration.isFinite && duration > 0 ? min(1, position / duration) : 0).tint(Palette.accent)
                            Text(Duration.seconds(position.isFinite ? position : 0), format: .time(pattern: .minuteSecond))
                                .apText(.sm).monospacedDigit().foregroundStyle(Palette.inkMuted)
                        }
                    }
                } else {
                    Text("Audio").apText(.sm).foregroundStyle(Palette.inkMuted)
                }
            }
        }
        .padding(.vertical, Tokens.Space.s1)
        .padding(.horizontal, Tokens.Space.s3)
        .frame(width: inCard ? nil : UploadEmbedView.maxWidth, alignment: .leading)
        .frame(maxWidth: inCard ? .infinity : nil, alignment: .leading)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
        .onDisappear {
            player?.pause()
            playing = false
            if let ended { NotificationCenter.default.removeObserver(ended) }
            ended = nil
            player = nil
        }
    }

    private func toggle() {
        if player == nil {
            let made = AVPlayer(url: url)
            ended = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: made.currentItem,
                                                           queue: .main) { _ in
                Task { @MainActor in
                    playing = false
                    made.seek(to: .zero)
                }
            }
            player = made
        }
        if playing {
            player?.pause()
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            player?.play()
        }
        playing.toggle()
    }
}

/// An embed of another kind (§3.5.2), as the web's EmbedCard when it has `og`: the image when the
/// server hosts it, the site, the title (else the embed's title or URL, else its kind), and two
/// lines of description. Without `og`, the labeled fallback card: the kind, and its title, URL
/// or text. `iframe` and `html`, which Ladle does not load, take the same two shapes. The card
/// is the link; tapping it opens `url` in the browser.
struct EmbedCard: View {
    let embed: Embed
    let policy: MediaPolicy

    var body: some View {
        if let og = embed.og {
            openGraph(og)
        } else if let url = embed.url {
            LinkButton(url: url) { fallback }
        } else {
            fallback
        }
    }

    private func openGraph(_ og: OpenGraph) -> some View {
        let player = og.player(policy: policy)
        return LinkCard(site: og.siteName, title: og.title ?? embed.title ?? embed.url?.absoluteString ?? embed.kind,
                        description: og.description, link: embed.url, playsPicture: player != nil) {
            switch player {
            case .video(let video, let poster):
                VideoTile(url: video.url, name: og.title ?? "link", aspect: video.aspectRatio ?? poster?.aspectRatio, poster: poster.map { .remote($0.url) }, inCard: true)
            case .audio(let audio, let cover):
                VStack(alignment: .leading, spacing: 0) {
                    if let cover { picture(cover) }
                    AudioCard(url: audio.url, name: og.title ?? "link", inCard: true)
                        .padding(.top, cover == nil ? Tokens.Space.s3 : Tokens.Space.s2)
                        .padding(.horizontal, Tokens.Space.s3)
                }
            case nil:
                if let image = og.image, policy.allowsMedia(image.url) { picture(image) }
            }
        }
    }

    private func picture(_ image: OpenGraph.Media) -> some View {
        RemoteImage(url: image.url)
            .aspectRatio(1.91, contentMode: .fit)
            .accessibilityLabel(image.alt ?? "")
            .accessibilityHidden(image.alt == nil)
    }

    private var fallback: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            Label(embed.kindLabel, systemImage: "square.dashed")
                .apText(.sm, .semibold).foregroundStyle(Palette.inkMuted)
            if let title = embed.title {
                Text(title).apText(.ui, .semibold).foregroundStyle(Palette.ink)
            }
            if let detail = embed.text ?? embed.url?.absoluteString {
                Text(detail).apText(.ui).foregroundStyle(embed.url == nil ? Palette.ink : Palette.denim).lineLimit(3)
            }
        }
        .frame(maxWidth: Tokens.Size.embedMaxW, alignment: .leading)
        .padding(Tokens.Space.s3)
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md).strokeBorder(Palette.line))
    }
}

/// The web's EmbedCard: the picture its caller gives, the site, the title, and two lines of
/// description, 420 pt wide at most. `link` is where a tap goes. When the picture is a player
/// (`playsPicture`), only the text opens it, so the player's controls never do.
struct LinkCard<Picture: View>: View {
    let site: String?
    let title: String
    var description: String?
    var link: URL?
    var playsPicture = false
    @ViewBuilder var picture: Picture

    var body: some View {
        if let link, !playsPicture {
            LinkButton(url: link) { card }
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            picture
            if let link, playsPicture {
                LinkButton(url: link) { text }
            } else {
                text
            }
        }
        .frame(maxWidth: Tokens.Size.embedCardW)
        .background(Palette.raised)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.lg).strokeBorder(Palette.line))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            if let site {
                Text(site).apText(.sm).foregroundStyle(Palette.inkMuted).lineLimit(1)
            }
            Text(title).apText(.body, .semibold).foregroundStyle(Palette.ink).lineLimit(1)
            if let description {
                Text(description).apText(.ui).foregroundStyle(Palette.inkMuted).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Tokens.Space.s3)
        .padding(.horizontal, Tokens.Space.s4)
        .contentShape(Rectangle())
    }
}

/// A card that opens `url` in the browser, with Open, Copy and Share in its context menu.
struct LinkButton<Label: View>: View {
    let url: URL
    @ViewBuilder var label: Label

    var body: some View {
        Link(destination: url) { label }
            .buttonStyle(.plain)
            .contextMenu {
                Link(destination: url) { SwiftUI.Label("Open Link", systemImage: "arrow.up.right.square") }
                Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.url = url }
                ShareLink(item: url)
            }
    }
}

extension EnvironmentValues {
    /// Opens the media viewer at an image or video embed.
    @Entry var openMedia = OpenMediaAction { _ in }
}

/// Opens the media viewer by media id; a struct so the environment can tell it apart.
struct OpenMediaAction {
    let open: (String) -> Void
    init(_ open: @escaping (String) -> Void) { self.open = open }
    func callAsFunction(_ mediaID: String) { open(mediaID) }
}
