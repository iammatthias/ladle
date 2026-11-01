import Foundation
import Observation

/// One embed's live text (v10 §4.8.5, §4.8.6) as this device reads it, shared by every view
/// that shows it, so a message and the full-screen terminal read `url` once (a server caps how
/// often a live text is read). It reads only while something shows it (`ServerSession.follow`).
@MainActor
@Observable
public final class LiveText {
    public enum Kind: Sendable { case terminal, append }

    public enum Phase: Hashable, Sendable {
        /// Asking, or waiting to ask again: what was shown stays.
        case connecting
        /// A response is arriving.
        case live
        /// `GET url` ended, or was refused for good: what was shown stays until the snapshot
        /// that finishes the embed.
        case ended
    }

    public let url: URL
    public let kind: Kind
    public private(set) var phase: Phase = .connecting
    /// An append's text after its edits, or a terminal's text since its response began, cut as
    /// `TerminalFeed` keeps it.
    public private(set) var text = ""
    /// A terminal's screen as a message shows it: no scrollback.
    public private(set) var screen = TerminalScreen()
    /// The full-screen viewer's screen, with `TerminalScreen.viewerScrollback`, while it is open.
    public private(set) var viewerScreen: TerminalScreen?
    /// What arrived, applied as it comes and shown at most once a frame (`frame`), as
    /// apron-web redraws a live text once an animation frame: a writer's many small chunks
    /// would otherwise each redraw the timeline.
    @ObservationIgnored private var arrivingText = ""
    @ObservationIgnored private var arrivingScreen = TerminalScreen()
    @ObservationIgnored private var arrivingViewer: TerminalScreen?
    @ObservationIgnored private var showing: Task<Void, Never>?
    @ObservationIgnored private var decoder = LiveTextDecoder()
    @ObservationIgnored var watchers = 0
    @ObservationIgnored var reading: Task<Void, Never>?
    static let frame = Duration.milliseconds(33)

    init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    /// Still arriving, or about to: the Live badge and "Writing…".
    public var isLive: Bool { phase != .ended }

    /// Opens the full-screen viewer's screen, from the text so far.
    public func openViewer() {
        arrivingViewer = TerminalScreen.showing(arrivingText, scrollback: TerminalScreen.viewerScrollback)
        viewerScreen = arrivingViewer
    }

    public func closeViewer() {
        arrivingViewer = nil
        viewerScreen = nil
    }

    func started() {
        decoder = LiveTextDecoder()
        phase = .live
        arrivingText = ""
        arrivingScreen.reset()
        arrivingViewer?.reset()
        show()
    }

    func received(_ data: Data) {
        add(decoder.decode(data))
        guard showing == nil else { return }
        showing = Task { [weak self] in
            try? await Task.sleep(for: Self.frame)
            self?.show()
        }
    }

    func ended() {
        add(decoder.finish())
        phase = .ended
        show()
    }

    private func show() {
        showing?.cancel()
        showing = nil
        if text != arrivingText { text = arrivingText }
        guard kind == .terminal else { return }
        screen = arrivingScreen
        if viewerScreen != nil { viewerScreen = arrivingViewer }
    }

    private func add(_ decoded: String) {
        guard !decoded.isEmpty else { return }
        switch kind {
        case .append:
            LiveTextEdit.apply(decoded, to: &arrivingText)
        case .terminal:
            arrivingText += decoded
            if arrivingText.utf16.count > TerminalFeed.keep + TerminalFeed.keep / 4 { arrivingText = TerminalFeed.keepLast(arrivingText) }
            arrivingScreen.write(decoded)
            arrivingViewer?.write(decoded)
        }
    }
}

extension Embed {
    /// A terminal with no `output` yet is live (§4.8.6); an append is live while it is there.
    public var isLiveText: Bool {
        (kind == "terminal" && output == nil) || kind == "append"
    }

    /// Live text whose write has not started: it has no `url` until then, when a snapshot adds
    /// one (§4.8.5). A `url` this device may not read is not waiting; it is unavailable.
    public var isWaitingForWriter: Bool { isLiveText && json["url"] == nil }
}

extension ServerSession {
    /// How many live texts are kept by `url` for rows that scroll away and back, as apron-web's
    /// `KEPT`.
    static let keptLiveTexts = 16

    /// The live text of a `terminal` or `append` embed, or nil when it is finished, has no
    /// `url`, or its `url` is not on the chat server's own origin (§4.8.5: clients should not
    /// connect to live text elsewhere). Nothing is read until a view `follow`s it.
    public func liveText(of embed: Embed) -> LiveText? {
        guard embed.isLiveText, let url = embed.url, MediaGate.origin(of: url) == mediaGate.origin else { return nil }
        let kind: LiveText.Kind = embed.kind == "terminal" ? .terminal : .append
        liveTextOrder.removeAll { $0 == url }
        liveTextOrder.append(url)
        if let kept = liveTexts[url] { return kept }
        let made = LiveText(url: url, kind: kind)
        liveTexts[url] = made
        let unwatched = liveTextOrder.filter { liveTexts[$0]?.watchers == 0 && $0 != url }
        for oldest in unwatched.prefix(max(0, liveTextOrder.count - Self.keptLiveTexts)) {
            liveTexts[oldest] = nil
            liveTextOrder.removeAll { $0 == oldest }
        }
        return made
    }

    /// Reads `live` while the calling task runs, as a view's `task` does: the first follower
    /// starts the request and the last one to stop cancels it, to be read afresh next time (a
    /// reconnect replaces what was shown).
    public func follow(_ live: LiveText) async {
        live.watchers += 1
        if live.reading == nil, live.phase != .ended {
            let read = environment.readLiveText
            let sleep = environment.sleep
            live.reading = Task { [weak live] in
                guard let url = live?.url else { return }
                await LiveTextFollow.run(url, read: read, sleep: sleep,
                                         started: { live?.started() }, bytes: { live?.received($0) }, ended: { live?.ended() })
                live?.reading = nil
            }
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(3600)) } catch { break }
        }
        live.watchers -= 1
        if live.watchers == 0 {
            live.reading?.cancel()
            live.reading = nil
        }
    }

    /// The text an `append` embed has streamed so far, while the message has one this device may read.
    public func appendedText(of message: MessageSnapshot) -> LiveText? {
        message.embedList.first(where: \.isAppend).flatMap(liveText(of:))
    }
}
