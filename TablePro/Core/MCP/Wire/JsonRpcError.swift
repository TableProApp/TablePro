import Foundation

public struct JsonRpcError: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JsonValue?

    public init(code: Int, message: String, data: JsonValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(Int.self, forKey: .code)
        message = try container.decode(String.self, forKey: .message)
        data = try container.decodeIfPresent(JsonValue.self, forKey: .data)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(data, forKey: .data)
    }
}

public extension JsonRpcError {
    static func parseError(message: String = "Parse error", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.parseError, message: message, data: data)
    }

    static func invalidRequest(message: String = "Invalid request", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.invalidRequest, message: message, data: data)
    }

    static func methodNotFound(message: String = "Method not found", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.methodNotFound, message: message, data: data)
    }

    static func invalidParams(message: String = "Invalid params", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.invalidParams, message: message, data: data)
    }

    static func internalError(message: String = "Internal error", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.internalError, message: message, data: data)
    }

    static func serverError(message: String = "Server error", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.serverError, message: message, data: data)
    }

    static func sessionNotFound(message: String = "Session not found", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.sessionNotFound, message: message, data: data)
    }

    static func requestCancelled(message: String = "Request cancelled", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.requestCancelled, message: message, data: data)
    }

    static func requestTimeout(message: String = "Request timeout", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.requestTimeout, message: message, data: data)
    }

    static func resourceNotFound(message: String = "Resource not found", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.resourceNotFound, message: message, data: data)
    }

    static func tooLarge(message: String = "Payload too large", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.tooLarge, message: message, data: data)
    }

    static func serverDisabled(message: String = "Server disabled", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.serverDisabled, message: message, data: data)
    }

    static func forbidden(message: String = "Forbidden", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.forbidden, message: message, data: data)
    }

    static func expired(message: String = "Expired", data: JsonValue? = nil) -> Self {
        Self(code: JsonRpcErrorCode.expired, message: message, data: data)
    }
}
