import Foundation

/// Writes an attachment's content to its `write_url` (§4.8.3): one HTTP `PUT` of the file, with
/// the attachment's type as `Content-Type`, reporting the fraction sent.
public typealias EmbedWrite = @Sendable (_ writeURL: URL, _ attachment: Attachment, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void

/// A write the server or the network refused.
public enum EmbedWriteError: Error, Hashable, Sendable, LocalizedError {
    /// 413: over the server's size limit for one file or one message.
    case tooLarge
    /// 415: a type the server does not take, such as a non-image avatar.
    case unsupportedType
    /// Another non-2xx status, with the server's text if it sent one.
    case refused(status: Int, message: String?)
    /// The request never completed: offline, or the connection dropped.
    case unreachable
    /// The result listed no write URL for the attachment.
    case notAccepted

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The file is larger than this server accepts."
        case .unsupportedType: "The server doesn't accept this type of file."
        case .refused(let status, let message): message.flatMap { $0.isEmpty ? nil : $0 } ?? "The server refused the upload (\(status))."
        case .unreachable: "The upload didn't reach the server."
        case .notAccepted: "The server didn't accept the attachment."
        }
    }

    /// Only the standard meanings of a status (RFC 9110); what else a server means is its own.
    public init(status: Int, body: Data) {
        switch status {
        case 413: self = .tooLarge
        case 415: self = .unsupportedType
        default:
            let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            self = .refused(status: status, message: text.isEmpty ? nil : text)
        }
    }
}

public enum EmbedWriter {
    /// The URLSession write. Write URLs are credentials (§4.8.3), so nothing is cached or sent
    /// with cookies.
    public static let live: EmbedWrite = { writeURL, attachment, progress in
        var request = URLRequest(url: writeURL)
        request.httpMethod = "PUT"
        request.setValue(attachment.contentType, forHTTPHeaderField: "Content-Type")
        request.httpShouldHandleCookies = false
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: attachment.fileURL, delegate: ProgressDelegate(progress))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw EmbedWriteError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else { throw EmbedWriteError(status: status, body: data) }
        progress(1)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        return URLSession(configuration: configuration)
    }()

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        let report: @Sendable (Double) -> Void

        init(_ report: @escaping @Sendable (Double) -> Void) {
            self.report = report
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        }
    }
}
