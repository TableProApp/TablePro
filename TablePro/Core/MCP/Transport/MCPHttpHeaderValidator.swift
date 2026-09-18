import Foundation

public enum MCPHttpHeaderValidator {
    public static let protocolVersionHeader = "MCP-Protocol-Version"
    public static let methodHeader = "Mcp-Method"
    public static let nameHeader = "Mcp-Name"
    public static let parameterHeaderPrefix = "Mcp-Param-"

    public static let nameCarryingMethods: Set<String> = ["tools/call", "resources/read", "prompts/get"]

    public static func validate(head: HttpRequestHead, message: JsonRpcMessage) -> MCPProtocolError? {
        guard let method = messageMethod(message) else { return nil }
        let params = messageParams(message)

        if let failure = validateProtocolVersion(head: head, params: params) { return failure }
        if let failure = validateMethod(head: head, method: method) { return failure }
        if let failure = validateName(head: head, method: method, params: params) { return failure }
        return validateParameters(head: head, method: method, params: params)
    }

    public static func hostIsLoopback(_ head: HttpRequestHead, expectedPort: UInt16) -> Bool {
        guard let raw = head.headers.value(for: "Host"), !raw.isEmpty else { return false }
        let (name, port) = splitHostPort(raw)
        if let port, port != expectedPort { return false }
        switch name.lowercased() {
        case "localhost", "127.0.0.1", "::1", "[::1]":
            return true
        default:
            return false
        }
    }

    private static func validateProtocolVersion(head: HttpRequestHead, params: JsonValue?) -> MCPProtocolError? {
        guard let headerValue = head.headers.value(for: protocolVersionHeader), !headerValue.isEmpty else {
            return .headerMismatch(detail: "\(protocolVersionHeader) header is required")
        }
        guard isValidHeaderValue(headerValue) else {
            return .headerMismatch(detail: "\(protocolVersionHeader) header contains invalid characters")
        }
        let bodyValue = MCPRequestMeta.metaObject(in: params)?[MCPMetaKeys.protocolVersion]?.stringValue
        guard let bodyValue else {
            return .headerMismatch(
                detail: "\(protocolVersionHeader) header is set but _meta.\(MCPMetaKeys.protocolVersion) is absent"
            )
        }
        guard headerValue == bodyValue else {
            return .headerMismatch(
                detail: "\(protocolVersionHeader) header value '\(headerValue)' does not match body value '\(bodyValue)'"
            )
        }
        return nil
    }

    private static func validateMethod(head: HttpRequestHead, method: String) -> MCPProtocolError? {
        guard let headerValue = head.headers.value(for: methodHeader), !headerValue.isEmpty else {
            return .headerMismatch(detail: "\(methodHeader) header is required")
        }
        guard isValidHeaderValue(headerValue) else {
            return .headerMismatch(detail: "\(methodHeader) header contains invalid characters")
        }
        guard headerValue == method else {
            return .headerMismatch(
                detail: "\(methodHeader) header value '\(headerValue)' does not match body value '\(method)'"
            )
        }
        return nil
    }

    private static func validateName(
        head: HttpRequestHead,
        method: String,
        params: JsonValue?
    ) -> MCPProtocolError? {
        guard nameCarryingMethods.contains(method) else { return nil }
        guard let headerValue = head.headers.value(for: nameHeader), !headerValue.isEmpty else {
            return .headerMismatch(detail: "\(nameHeader) header is required for \(method)")
        }
        guard isValidHeaderValue(headerValue), let decoded = MCPBase64Sentinel.decodeIfNeeded(headerValue) else {
            return .headerMismatch(detail: "\(nameHeader) header value is malformed")
        }
        let field = method == "resources/read" ? "uri" : "name"
        guard let bodyValue = params?[field]?.stringValue else {
            return .headerMismatch(detail: "\(nameHeader) header is set but params.\(field) is absent")
        }
        guard decoded == bodyValue else {
            return .headerMismatch(
                detail: "\(nameHeader) header value '\(decoded)' does not match body value '\(bodyValue)'"
            )
        }
        return nil
    }

    private static func validateParameters(
        head: HttpRequestHead,
        method: String,
        params: JsonValue?
    ) -> MCPProtocolError? {
        let scope = method == "tools/call" ? params?["arguments"] : params
        for (name, rawValue) in head.headers.pairs(withPrefix: parameterHeaderPrefix) {
            let parameterName = String(name.dropFirst(parameterHeaderPrefix.count))
            guard !parameterName.isEmpty, isFieldNameToken(parameterName) else {
                return .headerMismatch(detail: "'\(name)' is not a valid parameter header name")
            }
            guard isValidHeaderValue(rawValue), let decoded = MCPBase64Sentinel.decodeIfNeeded(rawValue) else {
                return .headerMismatch(detail: "'\(name)' header value is malformed")
            }
            guard let bodyValue = argumentValue(named: parameterName, in: scope) else {
                return .headerMismatch(detail: "'\(name)' header has no matching value in the request body")
            }
            guard valuesMatch(header: decoded, body: bodyValue) else {
                return .headerMismatch(detail: "'\(name)' header value does not match the request body value")
            }
        }
        return nil
    }

    private static func argumentValue(named name: String, in scope: JsonValue?) -> JsonValue? {
        guard let fields = scope?.objectValue else { return nil }
        let lowered = name.lowercased()
        for (key, value) in fields where key.lowercased() == lowered {
            return value
        }
        for (_, value) in fields {
            if case .object = value, let nested = argumentValue(named: name, in: value) {
                return nested
            }
        }
        return nil
    }

    private static func valuesMatch(header: String, body: JsonValue) -> Bool {
        switch body {
        case .string(let value):
            return header == value
        case .int(let value):
            guard let headerNumber = Double(header) else { return false }
            return headerNumber == Double(value)
        case .double(let value):
            guard let headerNumber = Double(header) else { return false }
            return headerNumber == value
        case .bool(let value):
            return header == (value ? "true" : "false")
        case .null, .array, .object:
            return false
        }
    }

    private static func messageMethod(_ message: JsonRpcMessage) -> String? {
        switch message {
        case .request(let request):
            return request.method
        case .notification(let notification):
            return notification.method
        case .successResponse, .errorResponse:
            return nil
        }
    }

    private static func messageParams(_ message: JsonRpcMessage) -> JsonValue? {
        switch message {
        case .request(let request):
            return request.params
        case .notification(let notification):
            return notification.params
        case .successResponse, .errorResponse:
            return nil
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value <= 0x7E)
        }
    }

    private static func isFieldNameToken(_ name: String) -> Bool {
        let allowed = Set("!#$%&'*+-.^_`|~")
        return name.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || allowed.contains(character))
        }
    }

    private static func splitHostPort(_ value: String) -> (String, UInt16?) {
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]") else { return (value, nil) }
            let host = String(value[value.startIndex...closing])
            let remainder = value[value.index(after: closing)...]
            guard remainder.hasPrefix(":") else { return (host, nil) }
            return (host, UInt16(remainder.dropFirst()))
        }
        guard let separator = value.lastIndex(of: ":") else { return (value, nil) }
        let host = String(value[value.startIndex..<separator])
        let port = UInt16(value[value.index(after: separator)...])
        guard port != nil else { return (value, nil) }
        return (host, port)
    }
}
