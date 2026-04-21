//
//  MCPMessageTypes.swift
//  TablePro
//

import Foundation

// MARK: - JSONValue

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }

        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }

        if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
            return
        }

        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
            return
        }

        if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
            return
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - JSONValue Literals

extension JSONValue: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    init(nilLiteral: ()) {
        self = .null
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - JSONValue Accessors

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

// MARK: - JSONRPCId

enum JSONRPCId: Codable, Equatable, Hashable, Sendable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
            return
        }

        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "JSONRPCId must be a string or integer")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        }
    }
}

// MARK: - JSON-RPC 2.0 Base Types

struct JSONRPCRequest: Codable, Sendable {
    let jsonrpc: String
    let id: JSONRPCId?
    let method: String
    let params: JSONValue?
}

struct JSONRPCResponse: Codable, Sendable {
    let id: JSONRPCId
    let result: JSONValue

    var jsonrpc: String { "2.0" }

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
    }

    init(id: JSONRPCId, result: JSONValue) {
        self.id = id
        self.result = result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decode(JSONRPCId.self, forKey: .id)
        result = try container.decode(JSONValue.self, forKey: .result)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(result, forKey: .result)
    }
}

struct JSONRPCErrorResponse: Codable, Sendable {
    let id: JSONRPCId?
    let error: JSONRPCErrorDetail

    var jsonrpc: String { "2.0" }

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case error
    }

    init(id: JSONRPCId?, error: JSONRPCErrorDetail) {
        self.id = id
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(JSONRPCId.self, forKey: .id)
        error = try container.decode(JSONRPCErrorDetail.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(error, forKey: .error)
    }
}

struct JSONRPCErrorDetail: Codable, Sendable {
    let code: Int
    let message: String
    let data: JSONValue?
}

// MARK: - MCPError

enum MCPError: Error, Sendable {
    case parseError
    case invalidRequest(String)
    case methodNotFound(String)
    case invalidParams(String)
    case internalError(String)
    case notConnected(UUID)
    case forbidden(String, context: [String: String]? = nil)
    case timeout(String, context: [String: String]? = nil)
    case resultTooLarge
    case serverDisabled

    var code: Int {
        switch self {
        case .parseError: -32_700
        case .invalidRequest: -32_600
        case .methodNotFound: -32_601
        case .invalidParams: -32_602
        case .internalError: -32_603
        case .notConnected: -32_000
        case .forbidden: -32_001
        case .timeout: -32_002
        case .resultTooLarge: -32_003
        case .serverDisabled: -32_004
        }
    }

    var message: String {
        switch self {
        case .parseError:
            "Parse error"
        case .invalidRequest(let detail):
            "Invalid request: \(detail)"
        case .methodNotFound(let method):
            "Method not found: \(method)"
        case .invalidParams(let detail):
            "Invalid params: \(detail)"
        case .internalError(let detail):
            "Internal error: \(detail)"
        case .notConnected(let connectionId):
            "Not connected: \(connectionId)"
        case .forbidden(let detail, _):
            "Forbidden: \(detail)"
        case .timeout(let detail, _):
            "Timeout: \(detail)"
        case .resultTooLarge:
            "Result too large"
        case .serverDisabled:
            "MCP server is disabled"
        }
    }

    private var contextData: JSONValue? {
        switch self {
        case .forbidden(_, let context), .timeout(_, let context):
            guard let context, !context.isEmpty else { return nil }
            var dict: [String: JSONValue] = [:]
            for (key, value) in context {
                dict[key] = .string(value)
            }
            return .object(dict)
        case .notConnected(let connectionId):
            return .object(["connection_id": .string(connectionId.uuidString)])
        default:
            return nil
        }
    }

    func toJsonRpcError(id: JSONRPCId?) -> JSONRPCErrorResponse {
        JSONRPCErrorResponse(
            id: id,
            error: JSONRPCErrorDetail(code: code, message: message, data: contextData)
        )
    }
}

// MARK: - MCP Initialize

struct MCPClientInfo: Codable, Sendable {
    let name: String
    let version: String?
}

struct MCPInitializeResult: Codable, Sendable {
    let protocolVersion: String
    let capabilities: MCPServerCapabilities
    let serverInfo: MCPServerInfo
}

struct MCPServerCapabilities: Codable, Sendable {
    let tools: ToolCapability?
    let resources: ResourceCapability?

    struct ToolCapability: Codable, Sendable {
        let listChanged: Bool
    }

    struct ResourceCapability: Codable, Sendable {
        let subscribe: Bool
        let listChanged: Bool
    }
}

struct MCPServerInfo: Codable, Sendable {
    let name: String
    let version: String
}

// MARK: - MCP Tools

struct MCPToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
}

struct MCPToolResult: Codable, Sendable {
    let content: [MCPContent]
    let isError: Bool?
}

struct MCPContent: Codable, Sendable {
    let type: String
    let text: String

    static func text(_ value: String) -> MCPContent {
        MCPContent(type: "text", text: value)
    }
}

// MARK: - MCP Resources

struct MCPResourceDefinition: Codable, Sendable {
    let uri: String
    let name: String
    let description: String?
    let mimeType: String?
}

struct MCPResourceContent: Codable, Sendable {
    let uri: String
    let mimeType: String?
    let text: String?
}

struct MCPResourceReadResult: Codable, Sendable {
    let contents: [MCPResourceContent]
}

