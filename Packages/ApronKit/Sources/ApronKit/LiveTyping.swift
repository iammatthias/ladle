import Foundation
import Synchronization

/// Writing live text (v10 §4.8.5) from the composer, as apron-web's `live-typing.ts` (#191).
public enum LiveEdit {
    /// The edit that turns live text the sender wrote, `sent`, into `next`, as typing makes it,
    /// as apron-web's `liveEdit`: what was typed at the end goes as it is, and one character
    /// deleted from the end (one grapheme, such as an emoji with its skin tone) as one backspace
    /// per code point, as readers apply them (`LiveTextEdit`). Any other change replaced text: a
    /// selection deleted or typed over, a word removed at once, an edit before the end. That goes
    /// as a form feed and all of `next`. Compared by code point: `String`'s own comparison treats
    /// canonically equivalent texts as equal, which readers do not.
    public static func between(_ sent: String, _ next: String) -> String {
        let old = sent.unicodeScalars, new = next.unicodeScalars
        if old.elementsEqual(new) { return "" }
        if new.starts(with: old) { return String(String.UnicodeScalarView(new.dropFirst(old.count))) }
        if old.starts(with: new) {
            let removed = old.dropFirst(new.count)
            if String(String.UnicodeScalarView(removed)).count == 1 { return String(repeating: "\u{08}", count: removed.count) }
        }
        return "\u{0C}" + next
    }

    /// A composer's text as it goes out as live text: without backspace and form feed, which
    /// would read as edits (apron-web's `liveTextOf`).
    public static func text(_ typed: String) -> String {
        String(String.UnicodeScalarView(typed.unicodeScalars.filter { $0 != "\u{08}" && $0 != "\u{0C}" }))
    }
}

/// The server's answer to a live text's write, which may come before the body ends: the text
/// reached a limit, or a save removed the embed.
public struct LiveTextWriteResponse: Hashable, Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data = Data()) {
        self.status = status
        self.body = body
    }

    /// The server's word on the ended write, its first line at most 200 characters, whatever the
    /// status: some servers say why with a success too.
    public var reason: String {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return String((text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "").prefix(200))
    }
}

/// Streams `body` to a `write_url` as one `PUT` (§4.8.3) whose end ends the text. Returns the
/// server's answer, and throws when the request could not be made or dropped.
public typealias LiveTextWrite = @Sendable (_ writeURL: URL, _ body: AsyncStream<Data>) async throws -> LiveTextWriteResponse

/// Why a live message stopped without being finished.
public struct LiveTypingEnd: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The message or its write never got going.
        case failed
        /// The server ended the text, or the connection dropped once text went out: the server
        /// keeps what arrived.
        case ended
    }

    public var kind: Kind
    /// The message, when it was posted.
    public var messageID: LogID?
    public var reason: String

    public init(_ kind: Kind, messageID: LogID? = nil, reason: String) {
        self.kind = kind
        self.messageID = messageID
        self.reason = reason
    }
}

/// One message typed live (`/live`), as apron-web's `LiveTyping`: posted at once with an `append`
/// embed, its live text following the composer. Each change goes out as the edit that turns what
/// was sent into the new text (`LiveEdit.between`). `finish` ends it for Send, and the caller
/// saves the message's final text, then `close`s the write.
@MainActor
public final class LiveTyping {
    public struct Transport {
        /// Posts the message with an `append` embed; returns it and the embed's `write_url`.
        public var start: @MainActor () async throws -> (messageID: LogID, writeURL: URL)
        public var write: LiveTextWrite

        public init(start: @escaping @MainActor () async throws -> (messageID: LogID, writeURL: URL), write: @escaping LiveTextWrite) {
            self.start = start
            self.write = write
        }
    }

    public private(set) var messageID: LogID?
    /// The composer's latest text, as typed.
    public private(set) var text: String
    /// That as live text (`LiveEdit.text`): what a save that ends it puts in `body.text`, so
    /// readers keep what they saw.
    public private(set) var liveText: String
    /// The live text written so far, without its edits.
    private var sent = ""
    private var body: AsyncStream<Data>.Continuation?
    private var done = false
    /// Some text went out on the write.
    private var wrote = false
    private var starting: Task<Void, Never>?

    public init(_ text: String = "", transport: Transport, onEnd: @escaping @MainActor (LiveTypingEnd) -> Void) {
        self.text = text
        liveText = LiveEdit.text(text)
        let end = { [weak self] (kind: LiveTypingEnd.Kind, reason: String) in
            guard let self, !self.done else { return }
            self.close()
            onEnd(LiveTypingEnd(kind, messageID: self.messageID, reason: reason))
        }
        starting = Task { [weak self] in
            let target: (messageID: LogID, writeURL: URL)
            do {
                target = try await transport.start()
            } catch {
                end(.failed, errorText(error))
                return
            }
            guard let self else { return }
            messageID = target.messageID
            if done { return }
            let (stream, continuation) = AsyncStream.makeStream(of: Data.self)
            body = continuation
            Task { [weak self] in
                do {
                    let response = try await transport.write(target.writeURL, stream)
                    let reason = response.reason
                    end(.ended, reason.isEmpty ? "the server ended it" : reason)
                } catch {
                    // Once text went out, the server keeps what arrived (§4.8.5): the message stands.
                    if self?.wrote == true { end(.ended, "the connection to the server dropped") } else { end(.failed, "this connection can’t stream live text") }
                }
            }
            update(self.text)
        }
    }

    /// Still following the composer: not finished, and not ended by the server or a failure.
    public var isActive: Bool { !done }

    /// Returns once the message is posted and its write has started, or failed to.
    public func started() async {
        await starting?.value
    }

    /// The composer's text changed: the edit to it goes out, once the write has started.
    public func update(_ text: String) {
        guard !done else { return }
        self.text = text
        liveText = LiveEdit.text(text)
        guard let body else { return }
        let edit = LiveEdit.between(sent, liveText)
        guard !edit.isEmpty else { return }
        body.yield(Data(edit.utf8))
        sent = liveText
        wrote = true
    }

    /// Ends it for Send: what is written stays, and no edit follows. Returns the message once its
    /// write started, for the caller to save its final text and then `close`; nil when it already
    /// ended (`onEnd` told why).
    public func finish() async -> LogID? {
        await started()
        if done { return nil }
        done = true
        return messageID
    }

    /// Ends the write: the body ends, so the text does, and the server keeps what arrived (§4.8.3).
    public func close() {
        done = true
        body?.finish()
        body = nil
    }
}

public enum LiveTextWriter {
    /// The URLSession write: an upload whose body is a bound stream pair fed as `body` yields,
    /// sent chunked over HTTP/1.1 and as DATA frames over HTTP/2, which URLSession negotiates on
    /// TLS. Write URLs are credentials (§4.8.3), so nothing is cached or sent with cookies.
    public static let live: LiveTextWrite = { writeURL, body in
        try await StreamedPut(writeURL).run(body)
    }
}

/// One streaming `PUT`: the body is written to a bound `OutputStream` off the main actor as it
/// arrives, and the server's status and text are collected until the task completes. Only the
/// pump writes to and closes the stream; it stops writing once the task has completed.
private final class StreamedPut: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var input: InputStream?
        var response: HTTPURLResponse?
        var data = Data()
        var completion: CheckedContinuation<LiveTextWriteResponse, any Error>?
        var completed = false
    }

    private let url: URL
    private let output: OutputStream
    private let state: Mutex<State>

    init(_ url: URL) {
        self.url = url
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 64 * 1024, inputStream: &input, outputStream: &output)
        self.output = output!
        state = Mutex(State(input: input))
    }

    func run(_ body: AsyncStream<Data>) async throws -> LiveTextWriteResponse {
        let configuration = URLSessionConfiguration.ephemeral
        // Typing pauses as long as the writer likes; the server ends a text that runs too long.
        configuration.timeoutIntervalForRequest = 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        let task = session.uploadTask(withStreamedRequest: request)
        output.open()
        let pump = Task.detached { [self] in
            for await chunk in body { write(chunk) }
            output.close()
        }
        defer { pump.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.completion = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func write(_ chunk: Data) {
        let bytes = [UInt8](chunk)
        var written = 0
        while written < bytes.count {
            if state.withLock({ $0.completed }) { return }
            let count = bytes[written...].withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            if count < 0 { return }
            if count == 0 { Thread.sleep(forTimeInterval: 0.005); continue }
            written += count
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        // A bound stream can't be read again, so a second ask (a redirect, a retry) gets none.
        completionHandler(state.withLock { state in
            defer { state.input = nil }
            return state.input
        })
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        state.withLock { $0.response = response as? HTTPURLResponse }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        state.withLock { $0.data.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (completion, answer) = state.withLock { state in
            state.completed = true
            defer { state.completion = nil }
            return (state.completion, state.response.map { LiveTextWriteResponse(status: $0.statusCode, body: state.data) })
        }
        session.finishTasksAndInvalidate()
        if let error {
            completion?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else {
            completion?.resume(returning: answer ?? LiveTextWriteResponse(status: 0))
        }
    }
}
