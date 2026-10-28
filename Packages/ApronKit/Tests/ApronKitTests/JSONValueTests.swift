import XCTest
@testable import ApronKit

final class JSONValueTests: XCTestCase {
    func testBigNumbersKeepTheirSourceText() throws {
        let text = #"{"id":"9007199254740993","n":18446744073709551616,"f":1.0,"e":-1.5e300}"#
        let value = try JSONValue(parsing: text)
        XCTAssertEqual(value["n"], .number("18446744073709551616"))
        XCTAssertEqual(value["f"], .number("1.0"))
        XCTAssertEqual(value["e"], .number("-1.5e300"))
        XCTAssertEqual(value["id"]?.stringValue, "9007199254740993")
        XCTAssertEqual(value.serialized(), #"{"e":-1.5e300,"f":1.0,"id":"9007199254740993","n":18446744073709551616}"#)
        XCTAssertNil(JSONValue.number("18446744073709551616").intValue)
        XCTAssertEqual(JSONValue.number("42").intValue, 42)
    }

    func testPrototypeLikeKeysAreOrdinaryKeys() throws {
        let text = #"{"__proto__":{"polluted":true},"constructor":"x","hasOwnProperty":false,"toString":null}"#
        let value = try JSONValue(parsing: text)
        XCTAssertEqual(value["__proto__"], ["polluted": true])
        XCTAssertEqual(value["constructor"], "x")
        XCTAssertEqual(value["hasOwnProperty"], false)
        XCTAssertEqual(value["toString"], .null)
        XCTAssertEqual(value.objectValue?.count, 4)
        XCTAssertEqual(try JSONValue(parsing: value.serialized()), value)
    }

    func testUnknownKeysSurviveParsingAndObjectsCompareUnordered() throws {
        let a = try JSONValue(parsing: #"{"method":"message","future_key":[1,{"x":null}],"params":{}}"#)
        let b = try JSONValue(parsing: #"{"params":{},"future_key":[1,{"x":null}],"method":"message"}"#)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a["future_key"], [1, ["x": nil]])
        XCTAssertNotEqual(a, try JSONValue(parsing: #"{"method":"message","params":{}}"#))
    }

    func testStringEscapesAndSurrogatePairs() throws {
        let value = try JSONValue(parsing: #"["👍","é\n\t\"\\\/","👍",""]"#)
        XCTAssertEqual(value, ["👍", "é\n\t\"\\/", "👍", ""])
        XCTAssertEqual(JSONValue.string("a\u{01}b\"").serialized(), #""a\u0001b\"""#)
        XCTAssertEqual(try JSONValue(parsing: #""\ud83d""#), .string("\u{FFFD}"))
    }

    func testDuplicateKeysKeepTheLastValue() throws {
        XCTAssertEqual(try JSONValue(parsing: #"{"a":1,"a":2}"#), ["a": 2])
    }

    func testRejectsMalformedDocuments() {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "tru", "01", "1.", "\"\u{01}\"", "{} x", "-"] {
            XCTAssertThrowsError(try JSONValue(parsing: bad), bad)
        }
    }

    func testCodePointOrderPutsPlusAndColonBeforeAt() {
        let ids = ["bob@example.org", "bob+tag@example.org", "bob:x@example.org", "@bob:example.org", "Bob", "éa", "ea", "👍", "z"]
        XCTAssertEqual(ids.sorted(by: codePointLess),
                       ["@bob:example.org", "Bob", "bob+tag@example.org", "bob:x@example.org", "bob@example.org", "ea", "z", "éa", "👍"])
    }

    func testEveryBundledFixtureRoundTrips() throws {
        let urls = try fixtureURLs()
        XCTAssertEqual(urls.count, 18)
        for url in urls {
            let data = try Data(contentsOf: url)
            let value = try JSONValue(parsing: data)
            let again = try JSONValue(parsing: value.serialized())
            XCTAssertEqual(value, again, url.lastPathComponent)
            XCTAssertEqual(value["format"], 4, url.lastPathComponent)
        }
    }
}

func fixtureURLs(file: StaticString = #filePath, line: UInt = #line) throws -> [URL] {
    guard let directory = Bundle.module.url(forResource: "replay", withExtension: nil, subdirectory: "Fixtures/wire") else {
        XCTFail("Fixtures/wire/replay missing from the test bundle; run scripts/sync-fixtures.sh", file: file, line: line)
        return []
    }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}
