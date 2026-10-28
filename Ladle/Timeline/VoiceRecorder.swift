import AVFoundation
import Observation
import SwiftUI

/// Records a voice clip as AAC in an `.m4a` file (`audio/mp4`), which the server describes as
/// `og.audio` (§4.8.1) and every Apron client can play. The clip is attached to the draft, not
/// sent, as apron-web does. Stops by itself at the size the server takes, when it says.
@MainActor
@Observable
final class VoiceRecorder {
    enum State: Equatable {
        case idle
        case recording(since: Date)
        case denied
    }

    private(set) var state = State.idle
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    /// Receives a clip stopped at the server's size limit, as if Add were tapped.
    @ObservationIgnored var onLimit: ((URL) -> Void)?

    /// Asks for the microphone the first time, then records until `finish` or `cancel`.
    /// `maxBytes` stops it at 95% of the server's limit for audio.
    func start(maxBytes: Int?) async {
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .denied
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker])
            try session.setActive(true)
            let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                .replacingOccurrences(of: ":", with: ".")
            let destination = try AttachmentStaging.importFolder().appending(path: "Voice note \(stamp).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
            let recorder = try AVAudioRecorder(url: destination, settings: settings)
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            file = destination
            state = .recording(since: .now)
            if let maxBytes {
                // 64 kbit/s is 8000 bytes a second.
                let seconds = Double(maxBytes) * 0.95 / 8000
                limitTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(seconds))
                    if !Task.isCancelled, let self, let clip = self.finish() { self.onLimit?(clip) }
                }
            }
        } catch {
            cancel()
        }
    }

    /// Stops and returns the clip.
    func finish() -> URL? {
        let clip = file
        stop()
        return clip
    }

    func cancel() {
        let clip = file
        stop()
        if let clip { try? FileManager.default.removeItem(at: clip.deletingLastPathComponent()) }
    }

    private func stop() {
        limitTask?.cancel()
        recorder?.stop()
        recorder = nil
        file = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// The composer while recording: a red dot, the time, Cancel and Add.
struct RecordingBar: View {
    let since: Date
    let cancel: () -> Void
    let done: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.s2) {
            Button("Discard Recording", systemImage: "trash", action: cancel)
                .labelStyle(.iconOnly)
                .foregroundStyle(Palette.danger)
                .touchTarget()
            Circle().fill(Palette.danger).frame(width: 8, height: 8).accessibilityHidden(true)
            Text("Recording").apText(.ui, .semibold).foregroundStyle(Palette.ink)
            Text(timerInterval: since ... .distantFuture, countsDown: false)
                .apText(.ui).monospacedDigit().foregroundStyle(Palette.inkMuted)
            Spacer(minLength: 0)
            Button("Add", action: done).buttonStyle(PrimaryButtonStyle())
                .accessibilityLabel("Add Voice Note")
        }
        .frame(minHeight: Tokens.Control.md + Tokens.Space.s2)
    }
}
