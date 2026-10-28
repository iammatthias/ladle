/// The wire envelope (§1.1): JSON-RPC shaped frames without the `jsonrpc` key.

public struct Request: Hashable, Sendable {
    public var id: String
    public var method: String
    public var params: JSONValue?

    public init(id: String, method: String, params: JSONValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    /// The frame as sent: no `jsonrpc`, `params` only when set.
    public var encoded: JSONValue {
        var members: [String: JSONValue] = ["id": .string(id), "method": .string(method)]
        if let params { members["params"] = params }
        return .object(members)
    }
}

public struct WireNotification: Hashable, Sendable {
    public var method: String
    public var params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }

    public var encoded: JSONValue {
        var members: [String: JSONValue] = ["method": .string(method)]
        if let params { members["params"] = params }
        return .object(members)
    }
}

public struct RPCError: Error, Hashable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    /// The codes §1.1 names.
    public enum Code {
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let unsupported = -32601
        public static let invalidParams = -32602
        public static let internalError = -32603
        public static let denied = -32001
        public static let retryAfter = -32002
        public static let tooLarge = -32003
    }

    public var encoded: JSONValue {
        var members: [String: JSONValue] = ["code": .number(String(code)), "message": .string(message)]
        if let data { members["data"] = data }
        return .object(members)
    }
}

public struct Response: Hashable, Sendable {
    public var id: String
    public var outcome: Result<JSONValue, RPCError>

    public init(id: String, outcome: Result<JSONValue, RPCError>) {
        self.id = id
        self.outcome = outcome
    }

    public var encoded: JSONValue {
        switch outcome {
        case .success(let result): return .object(["id": .string(id), "result": result])
        case .failure(let error): return .object(["id": .string(id), "error": error.encoded])
        }
    }
}

public enum Frame: Hashable, Sendable {
    case request(Request)
    case response(Response)
    case notification(WireNotification)
    /// An error without an `id`, such as "Server at capacity" (§1.1).
    case error(RPCError)
}

public struct FrameDecodingError: Error, Equatable, Sendable, CustomStringConvertible {
    public let reason: String
    public var description: String { "invalid frame: \(reason)" }
}

extension Frame {
    /// Classifies a parsed frame. Unknown keys and `jsonrpc` are ignored.
    public init(decoding value: JSONValue) throws(FrameDecodingError) {
        guard case .object(let members) = value else { throw FrameDecodingError(reason: "not an object") }
        let id = members["id"]?.stringValue
        if let method = members["method"]?.stringValue {
            if let id {
                self = .request(Request(id: id, method: method, params: members["params"]))
            } else {
                self = .notification(WireNotification(method: method, params: members["params"]))
            }
            return
        }
        if members["method"] != nil { throw FrameDecodingError(reason: "method is not a string") }
        if let result = members["result"] {
            guard let id else { throw FrameDecodingError(reason: "result without a string id") }
            self = .response(Response(id: id, outcome: .success(result)))
            return
        }
        if let error = members["error"] {
            let decoded = try RPCError(decoding: error)
            self = id.map { .response(Response(id: $0, outcome: .failure(decoded))) } ?? .error(decoded)
            return
        }
        throw FrameDecodingError(reason: "neither method, result, nor error")
    }

    public init(parsing text: String) throws {
        try self.init(decoding: try JSONValue(parsing: text))
    }

    public var encoded: JSONValue {
        switch self {
        case .request(let request): return request.encoded
        case .response(let response): return response.encoded
        case .notification(let notification): return notification.encoded
        case .error(let error): return .object(["error": error.encoded])
        }
    }
}

extension RPCError {
    init(decoding value: JSONValue) throws(FrameDecodingError) {
        guard case .object(let members) = value, let code = members["code"]?.intValue else {
            throw FrameDecodingError(reason: "error without an integer code")
        }
        self.init(code: code, message: members["message"]?.stringValue ?? "", data: members["data"])
    }
}
