import ApronKit
import AVFoundation

/// The AVFoundation half of `UploadPlan`: a sound re-encoded as AAC at a bit rate that fits, and
/// a video exported at smaller presets until one fits. Each writes a new file into `folder`;
/// `AttachmentPreparer` then checks the result against the server's limits again.
enum MediaCompression {
    enum Failure: LocalizedError {
        case tooLong(maxBytes: Int)
        case tooLarge
        case unreadable

        var errorDescription: String? {
            switch self {
            case .tooLong(let maxBytes):
                "This recording is too long for this server, which takes audio up to \(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .binary))."
            case .tooLarge: "This video can't be made small enough for this server."
            case .unreadable: "This file can't be read."
            }
        }
    }

    /// Mono AAC in an `.m4a`, at the best `AudioEncoding` step whose length fits `maxBytes`.
    static func audio(_ source: URL, maxBytes: Int?, named name: String, into folder: URL) throws -> URL {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch { throw Failure.unreadable }
        let seconds = Double(input.length) / input.processingFormat.sampleRate
        guard let encoding = AudioEncoding.fitting(maxBytes: maxBytes, seconds: seconds) else { throw Failure.tooLong(maxBytes: maxBytes ?? 0) }
        let destination = folder.appending(path: name)
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: encoding.sampleRate, AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: encoding.bitRate,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let converter = AVAudioConverter(from: input.processingFormat, to: output.processingFormat),
              let pending = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192)
        else { throw Failure.unreadable }
        var ended = false
        while true {
            guard let converted = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 8192) else { throw Failure.unreadable }
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if !ended, (try? input.read(into: pending)) != nil, pending.frameLength > 0 {
                    state.pointee = .haveData
                    return pending
                }
                ended = true
                state.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            if converted.frameLength > 0 { try output.write(from: converted) }
            if status == .endOfStream || status == .error { break }
        }
        return destination
    }

    /// Presets from the largest to the smallest that still shows what was filmed.
    private static let presets = [
        AVAssetExportPreset1920x1080, AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPreset640x480,
        AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality,
    ]

    /// The video exported as `type` at the first preset whose estimate fits `maxBytes`, trying
    /// the next when the export comes out larger than estimated.
    static func video(_ source: URL, type: String, maxBytes: Int?, named name: String, into folder: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let fileType: AVFileType = type == "video/mp4" ? .mp4 : .mov
        let destination = folder.appending(path: name)
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            if let maxBytes, let estimate = try? await session.estimatedOutputFileLengthInBytes, estimate > maxBytes { continue }
            try? FileManager.default.removeItem(at: destination)
            try await session.export(to: destination, as: fileType)
            let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
            if maxBytes.map({ size <= $0 }) ?? true { return destination }
        }
        throw Failure.tooLarge
    }
}
