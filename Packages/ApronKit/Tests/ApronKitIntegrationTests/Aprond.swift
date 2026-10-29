import Darwin
import Foundation
import Synchronization
import XCTest

/// One `aprond` process with an in-memory store on a free loopback port. The binary is copied to
/// a temporary directory first, because its build tree may be rebuilt while tests run.
final class Aprond: @unchecked Sendable {
    /// `APROND` overrides the default, the sibling `apron-server-rust` checkout's release build.
    static let binary: URL = {
        if let path = ProcessInfo.processInfo.environment["APROND"] { return URL(filePath: path) }
        return URL(filePath: #filePath)
            .appending(path: "../../../../../../apron-server-rust/target/release/aprond")
            .standardized
    }()

    let port: Int
    let directory: URL
    /// Signs in as the admin from any origin. `/avatar` needs an account that is not a guest.
    let adminToken = "admin-token-\(UUID().uuidString)"
    private let process: Process
    private let log = LogBuffer()

    private final class LogBuffer: Sendable {
        private let text = Mutex("")
        func append(_ more: String) { text.withLock { $0 += more } }
        var contents: String { text.withLock { $0 } }
    }

    var url: URL { URL(string: "ws://127.0.0.1:\(port)/ws")! }

    /// Skips the test when the binary is missing, or fails it when `APRON_REQUIRE_SERVER=1`.
    /// `arguments` go after the defaults, such as `--upload.max-mb 1`. The defaults let guests post
    /// (read-only otherwise) and offer passkeys to the origin Ladle presents for this port.
    static func start(_ arguments: [String] = [], file: StaticString = #filePath, line: UInt = #line) async throws -> Aprond {
        guard FileManager.default.isExecutableFile(atPath: binary.path()) else {
            let message = "aprond not found at \(binary.path()); build apron-server-rust or set APROND"
            if ProcessInfo.processInfo.environment["APRON_REQUIRE_SERVER"] == "1" {
                XCTFail(message, file: file, line: line)
            }
            throw XCTSkip(message)
        }
        let server = try Aprond(arguments: arguments)
        try await server.waitForLog("listening")
        return server
    }

    private init(arguments: [String]) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "aprond-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appending(path: "aprond")
        try FileManager.default.copyItem(at: Self.binary, to: copy)
        port = try Self.freePort()
        let tokenFile = directory.appending(path: "admin-token")
        try adminToken.write(to: tokenFile, atomically: true, encoding: .utf8)
        process = Process()
        process.executableURL = copy
        process.currentDirectoryURL = directory
        process.arguments = ["--store", "memory", "--addr", "127.0.0.1:\(port)", "--email.enable", "--email.sender", "log",
                             "--guest.posting", "--webauthn.origin", "https://127.0.0.1:\(port)",
                             "--admin-token-file", tokenFile.path()] + arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        let log = log
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            log.append(text)
        }
        try process.run()
    }

    /// Stops the process and deletes its directory.
    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// The code the log sender wrote for the address, from a line like `to=<address> code=<digits>`.
    func emailCode(for address: String) async throws -> String {
        let pattern = try Regex<(Substring, Substring)>("to=\"?\(NSRegularExpression.escapedPattern(for: address))\"? code=\"?([0-9]+)")
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let match = log.contents.matches(of: pattern).last { return String(match.output.1) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failure(message: "no email code for \(address) in the server log")
    }

    private func waitForLog(_ text: String) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if log.contents.contains(text) { return }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let output = log.contents
        stop()
        throw Failure(message: "aprond did not start: \(output)")
    }

    struct Failure: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    /// Binds port 0 on loopback and returns the port the kernel chose.
    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket failed") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
            }
        }
        guard bound else { throw Failure(message: "bind failed") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
