import XCTest
@testable import ApronKit

/// The protocol's client conformance gate: every replay fixture, every variant, run once with the
/// literal frames and once with `"jsonrpc":"2.0"` added to each frame (wire/README.md "Run").
final class ReplayFixtureTests: XCTestCase {
    func test01Creation() throws { try runFixture("01-creation") }
    func test02FullReplacement() throws { try runFixture("02-full-replacement") }
    func test03LiteralNull() throws { try runFixture("03-literal-null") }
    func test04ArrayReplacement() throws { try runFixture("04-array-replacement") }
    func test05Tombstone() throws { try runFixture("05-tombstone") }
    func test06DuplicateReplay() throws { try runFixture("06-duplicate-replay") }
    func test07SnapshotLoaded() throws { try runFixture("07-snapshot-loaded") }
    func test08SnapshotUnloaded() throws { try runFixture("08-snapshot-unloaded") }
    func test09HistoryEquivalence() throws { try runFixture("09-history-equivalence") }
    func test10ExtAndUnknownKeys() throws { try runFixture("10-ext-and-unknown-keys") }
    func test11NumericOrdering() throws { try runFixture("11-numeric-ordering") }
    func test12RoomMoves() throws { try runFixture("12-room-moves") }
    func test13RoomRecords() throws { try runFixture("13-room-records") }
    func test14Reactions() throws { try runFixture("14-reactions") }
    func test15EmbeddedSnapshots() throws { try runFixture("15-embedded-snapshots") }
    func test16TransientNotices() throws { try runFixture("16-transient-notices") }
    func test17Memberships() throws { try runFixture("17-memberships") }
    func test18UserIDForms() throws { try runFixture("18-user-id-forms") }

    /// Every bundled file, so a fixture added upstream without a method above still runs, and the
    /// totals the report quotes are measured here.
    func testEveryBundledFixtureAndTotals() throws {
        var totals = Totals()
        for url in try fixtureURLs() {
            totals.add(try run(fixtureAt: url))
        }
        print("replay fixtures: \(totals.files) files, \(totals.variants) variants, \(totals.runs) runs, \(totals.expectChecks) expect checks")
        XCTAssertEqual(totals.files, 18)
        XCTAssertEqual(totals.variants, 42)
        XCTAssertEqual(totals.runs, 84)
    }

    private struct Totals {
        var files = 0, variants = 0, runs = 0, expectChecks = 0
        mutating func add(_ other: Totals) {
            files += other.files; variants += other.variants; runs += other.runs; expectChecks += other.expectChecks
        }
    }

    private func runFixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard let url = try fixtureURLs().first(where: { $0.lastPathComponent == "\(name).json" }) else {
            XCTFail("\(name).json is not in the test bundle", file: file, line: line)
            return
        }
        let totals = try run(fixtureAt: url, file: file, line: line)
        XCTAssertGreaterThan(totals.variants, 0, name, file: file, line: line)
    }

    private func run(fixtureAt url: URL, file: StaticString = #filePath, line: UInt = #line) throws -> Totals {
        let name = url.lastPathComponent
        let fixture = try JSONValue(parsing: Data(contentsOf: url))
        XCTAssertEqual(fixture["format"], 4, "\(name) format", file: file, line: line)
        XCTAssertEqual(fixture["kind"], "replay", "\(name) kind", file: file, line: line)
        XCTAssertEqual(Set(fixture.objectValue?.keys ?? [:].keys),
                       ["description", "expected", "format", "kind", "name", "references", "variants"],
                       "\(name) top-level keys", file: file, line: line)
        guard let variants = fixture["variants"]?.arrayValue, !variants.isEmpty, let expected = fixture["expected"] else {
            XCTFail("\(name) has no variants or no expected", file: file, line: line)
            return Totals(files: 1)
        }
        var totals = Totals(files: 1, variants: variants.count)
        for variant in variants {
            let variantName = variant["name"]?.stringValue ?? "?"
            for envelope in [Envelope.literal, .jsonrpc] {
                var store = ReplayStore()
                for (index, step) in (variant["steps"]?.arrayValue ?? []).enumerated() {
                    let label = "\(name)/\(variantName)/\(envelope)/step-\(index)"
                    guard let members = step.objectValue, members.count == 1, let (operation, payload) = members.first else {
                        XCTFail("\(label): a step has exactly one key", file: file, line: line)
                        continue
                    }
                    switch operation {
                    case "receive":
                        try apply(frame: envelope.wrap(payload), to: &store, label: label, file: file, line: line)
                    case "expect":
                        totals.expectChecks += 1
                        assertProjection(store, equals: payload, label, file: file, line: line)
                    default:
                        XCTFail("\(label): unknown step \(operation)", file: file, line: line)
                    }
                }
                assertProjection(store, equals: expected, "\(name)/\(variantName)/\(envelope)/expected", file: file, line: line)
                totals.runs += 1
            }
        }
        return totals
    }

    private enum Envelope: CustomStringConvertible {
        case literal, jsonrpc

        var description: String { self == .literal ? "literal" : "jsonrpc" }

        /// Adds `"jsonrpc":"2.0"` at the top level only; nested data stays as is.
        func wrap(_ frame: JSONValue) -> JSONValue {
            guard self == .jsonrpc, var members = frame.objectValue else { return frame }
            members["jsonrpc"] = "2.0"
            return .object(members)
        }
    }

    /// The frame-to-store adapter (README "Decoding"): notifications carry records directly, and a
    /// result is a history page when it has `more`, else a `room_list` when it lists rooms.
    private func apply(frame: JSONValue, to store: inout ReplayStore, label: String, file: StaticString, line: UInt) throws {
        switch try Frame(decoding: frame) {
        case .notification(let notification):
            guard let records = Records(notification: notification) else {
                XCTFail("\(label): unsupported notification \(notification.method)", file: file, line: line)
                return
            }
            if notification.method == "message", case .invalid = MessageFrame(params: notification.params) {
                XCTFail("\(label): invalid message snapshot", file: file, line: line)
            }
            store.apply(records)
        case .response(let response):
            guard case .success(let result) = response.outcome else {
                XCTFail("\(label): replay fixtures carry no error replies", file: file, line: line)
                return
            }
            if result["more"]?.boolValue != nil {
                store.apply(Records(historyResult: result))
            } else if result["joined"]?.arrayValue != nil || result["not_joined"]?.arrayValue != nil {
                store.apply(Records(roomListResult: result))
            } else {
                XCTFail("\(label): a result must be a history page or a room_list", file: file, line: line)
            }
        case .request, .error:
            XCTFail("\(label): unexpected frame kind", file: file, line: line)
        }
    }

    private func assertProjection(_ store: ReplayStore, equals expected: JSONValue, _ label: String, file: StaticString, line: UInt) {
        let actual = store.projection()
        if actual != expected {
            XCTFail("\(label)\n  actual:   \(actual.serialized())\n  expected: \(expected.serialized())", file: file, line: line)
        }
    }
}
