import Foundation

public enum JsonRpcDecodingError: Error, Equatable, Sendable {
    case missingJsonRpcVersion
    case invalidJsonRpcVersion(String)
    case ambiguousMessage
    case missingMethod
    case missingResultOrError
    case batchUnsupported
}

public struct JsonRpcRequest: Codable, Equatable, Sendable {
    public let id: JsonRpcId
    public let method: String
    public let params: JsonValue?

    public init(id: JsonRpcId, method: String, params: JsonValue? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try container.decodeIfPresent(String.self, forKey: .jsonrpc) else {
            throw JsonRpcDecodingError.missingJsonRpcVersion
        }
        guard version == JsonRpcVersion.current else {
            throw JsonRpcDecodingError.invalidJsonRpcVersion(version)
        }
        id = try container.decode(JsonRpcId.self, forKey: .id)
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JsonValue.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(JsonRpcVersion.current, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

public struct JsonRpcNotification: Codable, Equatable, Sendable {
    public let method: String
    public let params: JsonValue?

    public init(method: String, params: JsonValue? = nil) {
        self.method = method
        self.params = params
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case method
        case params
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try container.decodeIfPresent(String.self, forKey: .jsonrpc) else {
            throw JsonRpcDecodingError.missingJsonRpcVersion
        }
        guard version == JsonRpcVersion.current else {
            throw JsonRpcDecodingError.invalidJsonRpcVersion(version)
        }
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JsonValue.self, forKey: .params)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(JsonRpcVersion.current, forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

public struct JsonRpcSuccessResponse: Codable, Equatable, Sendable {
    public let id: JsonRpcId
    public let result: JsonValue

    public init(id: JsonRpcId, result: JsonValue) {
        self.id = id
        self.result = result
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try container.decodeIfPresent(String.self, forKey: .jsonrpc) else {
            throw JsonRpcDecodingError.missingJsonRpcVersion
        }
        guard version == JsonRpcVersion.current else {
            throw JsonRpcDecodingError.invalidJsonRpcVersion(version)
        }
        id = try container.decode(JsonRpcId.self, forKey: .id)
        result = try container.decode(JsonValue.self, forKey: .result)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(JsonRpcVersion.current, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(result, forKey: .result)
    }
}

public struct JsonRpcErrorResponse: Codable, Equatable, Sendable {
    public let id: JsonRpcId?
    public let error: JsonRpcError

    public init(id: JsonRpcId?, error: JsonRpcError) {
        self.id = id
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let version = try container.decodeIfPresent(String.self, forKey: .jsonrpc) else {
            throw JsonRpcDecodingError.missingJsonRpcVersion
        }
        guard version == JsonRpcVersion.current else {
            throw JsonRpcDecodingError.invalidJsonRpcVersion(version)
        }
        if container.contains(.id) {
            id = try container.decode(JsonRpcId.self, forKey: .id)
        } else {
            id = nil
        }
        error = try container.decode(JsonRpcError.self, forKey: .error)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(JsonRpcVersion.current, forKey: .jsonrpc)
        if let id {
            try container.encode(id, forKey: .id)
        } else {
            try container.encode(JsonRpcId.null, forKey: .id)
        }
        try container.encode(error, forKey: .error)
    }
}

public enum JsonRpcMessage: Equatable, Sendable {
    case request(JsonRpcRequest)
    case notification(JsonRpcNotification)
    case successResponse(JsonRpcSuccessResponse)
    case errorResponse(JsonRpcErrorResponse)
}

extension JsonRpcMessage: Codable {
    enum DiscriminatorKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
        case result
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKeys.self)

        guard let version = try container.decodeIfPresent(String.self, forKey: .jsonrpc) else {
            throw JsonRpcDecodingError.missingJsonRpcVersion
        }
        guard version == JsonRpcVersion.current else {
            throw JsonRpcDecodingError.invalidJsonRpcVersion(version)
        }

        let hasId = container.contains(.id)
        let hasMethod = container.contains(.method)
        let hasResult = container.contains(.result)
        let hasError = container.contains(.error)

        if hasMethod, hasResult || hasError {
            throw JsonRpcDecodingError.ambiguousMessage
        }

        if hasResult, hasError {
            throw JsonRpcDecodingError.ambiguousMessage
        }

        if hasMethod {
            if hasId {
                self = .request(try JsonRpcRequest(from: decoder))
                return
            }
            self = .notification(try JsonRpcNotification(from: decoder))
            return
        }

        if hasResult {
            self = .successResponse(try JsonRpcSuccessResponse(from: decoder))
            return
        }

        if hasError {
            self = .errorResponse(try JsonRpcErrorResponse(from: decoder))
            return
        }

        if hasId {
            throw JsonRpcDecodingError.missingResultOrError
        }

        throw JsonRpcDecodingError.missingMethod
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .request(let request):
            try request.encode(to: encoder)
        case .notification(let notification):
            try notification.encode(to: encoder)
        case .successResponse(let response):
            try response.encode(to: encoder)
        case .errorResponse(let response):
            try response.encode(to: encoder)
        }
    }
}

public extension JsonRpcMessage {
    static func decode(from data: Data) throws -> JsonRpcMessage {
        guard let firstNonWhitespace = data.first(where: { !$0.isAsciiWhitespace }) else {
            throw JsonRpcDecodingError.missingJsonRpcVersion
        }
        if firstNonWhitespace == 0x5B {
            throw JsonRpcDecodingError.batchUnsupported
        }

        let decoder = JSONDecoder()
        return try decoder.decode(JsonRpcMessage.self, from: data)
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        return try encoder.encode(self)
    }
}

private extension UInt8 {
    var isAsciiWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}
