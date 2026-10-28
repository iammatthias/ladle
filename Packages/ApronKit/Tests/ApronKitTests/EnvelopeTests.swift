import XCTest
@testable import ApronKit

final class EnvelopeTests: XCTestCase {
    func testDecodesEachFrameShapeAndIgnoresJsonrpcAndUnknownKeys() throws {
        XCTAssertEqual(try Frame(parsing: #"{"jsonrpc":"2.0","method":"activity","params":{"room_id":"general","typing":8},"future":1}"#),
                       .notification(WireNotification(method: "activity", params: ["room_id": "general", "typing": 8])))
        XCTAssertEqual(try Frame(parsing: #"{"method":"ping"}"#), .notification(WireNotification(method: "ping")))
        XCTAssertEqual(try Frame(parsing: #"{"id":"c42","result":{"message_id":"1724803200042"},"jsonrpc":"2.0"}"#),
                       .response(Response(id: "c42", outcome: .success(["message_id": "1724803200042"]))))
        XCTAssertEqual(try Frame(parsing: #"{"id":"c43","error":{"code":-32002,"message":"Too Many Requests","data":{"retry_after":30}}}"#),
                       .response(Response(id: "c43", outcome: .failure(RPCError(code: -32002, message: "Too Many Requests", data: ["retry_after": 30])))))
        XCTAssertEqual(try Frame(parsing: #"{"error":{"code":-32002,"message":"Server at capacity"}}"#),
                       .error(RPCError(code: -32002, message: "Server at capacity")))
        XCTAssertEqual(try Frame(parsing: #"{"method":"message","id":"c3","params":{"body":{"text":"hi"}}}"#),
                       .request(Request(id: "c3", method: "message", params: ["body": ["text": "hi"]])))
    }

    func testRejectsFramesWithoutAShape() {
        for bad in [#"{}"#, #"[]"#, #"{"id":"x"}"#, #"{"result":{}}"#, #"{"id":"x","error":{"message":"no code"}}"#, #"{"method":5}"#] {
            XCTAssertThrowsError(try Frame(parsing: bad), bad)
        }
    }

    func testOutgoingFramesOmitJsonrpcAndCarryStringIDs() {
        XCTAssertEqual(Request(id: "c1", method: "auth", params: ["scheme": "guest"]).encoded.serialized(),
                       #"{"id":"c1","method":"auth","params":{"scheme":"guest"}}"#)
        XCTAssertEqual(WireNotification(method: "ping").encoded.serialized(), #"{"method":"ping"}"#)
        XCTAssertEqual(Response(id: "c1", outcome: .failure(RPCError(code: RPCError.denied, message: "no"))).encoded.serialized(),
                       #"{"error":{"code":-32001,"message":"no"},"id":"c1"}"#)
    }

    func testServerFrameDecodesTyped() throws {
        let params: JSONValue = [
            "apron": 9, "agent": "impl/1.0", "capabilities": ["history", "edit"], "auth": ["webauthn", "token"],
            "signup": ["guest"], "welcome": "Hi", "ping": 25, "status": ["dnd"], "push": ["kinds": ["relay"]],
            "ext": ["irc": ["network": "libera"]], "future": true,
        ]
        let server = try XCTUnwrap(ServerInfo(params: params))
        XCTAssertEqual(server.apron, 9)
        XCTAssertEqual(server.auth, ["webauthn", "token"])
        XCTAssertEqual(server.capabilities, ["history", "edit"])
        XCTAssertTrue(server.has("edit"))
        XCTAssertFalse(server.has("rooms"))
        XCTAssertEqual(server.signup, ["guest"])
        XCTAssertEqual(server.welcome, "Hi")
        XCTAssertEqual(server.ping, 25)
        XCTAssertEqual(server.status, ["dnd"])
        XCTAssertEqual(server.push, ["kinds": ["relay"]])
        XCTAssertEqual(server.ext, ["irc": ["network": "libera"]])

        let minimal = try XCTUnwrap(ServerInfo(params: ["apron": 9, "auth": ["guest"]]))
        XCTAssertEqual(minimal.capabilities, [])
        XCTAssertNil(minimal.ping)
        XCTAssertNil(minimal.signup)
        XCTAssertNil(ServerInfo(params: ["auth": ["guest"]]))
        XCTAssertNil(ServerInfo(params: ["apron": 9]))
    }

    func testLogIDsCompareNumerically() {
        XCTAssertLessThan(LogID("9")!, LogID("10")!)
        XCTAssertLessThan(LogID("1724803200042")!, LogID("1724803200043")!)
        XCTAssertEqual(LogID("100"), LogID("100"))
        for bad in ["", "0", "01", "-1", "1.5", "abc", "9007199254740992", "12345678901234567"] {
            XCTAssertNil(LogID(bad), bad)
        }
        XCTAssertNotNil(LogID("9007199254740991"))
        XCTAssertEqual(["10", "9", "100", "1"].compactMap(LogID.init).sorted().map(\.text), ["1", "9", "10", "100"])
    }
}
