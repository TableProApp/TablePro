import Foundation

public struct MCPRequestMeta: Sendable, Equatable {
    public let protocolVersion: MCPProtocolVersion
    public let clientInfo: MCPImplementation?
    public let clientCapabilities: MCPClientCapabilities
    public let progressToken: MCPProgressToken?
    public let traceContext: [String: String]

    public init(
        protocolVersion: MCPProtocolVersion,
        clientInfo: MCPImplementation?,
        clientCapabilities: MCPClientCapabilities,
        progressToken: MCPProgressToken?,
        traceContext: [String: String] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.clientInfo = clientInfo
        self.clientCapabilities = clientCapabilities
        self.progressToken = progressToken
        self.traceContext = traceContext
    }

    public var era: MCPEra {
        protocolVersion.era
    }

    public static func metaObject(in params: JsonValue?) -> JsonValue? {
        params?["_meta"]
    }

    public static func declaresModernProtocol(params: JsonValue?) -> Bool {
        metaObject(in: params)?[MCPMetaKeys.protocolVersion]?.stringValue != nil
    }

    public static func decodeModern(params: JsonValue?) throws -> MCPRequestMeta {
        let meta = metaObject(in: params)
        guard let versionValue = meta?[MCPMetaKeys.protocolVersion]?.stringValue, !versionValue.isEmpty else {
            throw MCPProtocolError.invalidParams(
                detail: "_meta.\(MCPMetaKeys.protocolVersion) is required"
            )
        }
        let version = MCPProtocolVersion(versionValue)
        guard version.isSupported else {
            throw MCPProtocolError.unsupportedProtocolVersion(requested: versionValue)
        }
        guard let capabilitiesValue = meta?[MCPMetaKeys.clientCapabilities],
              case .object = capabilitiesValue else {
            throw MCPProtocolError.invalidParams(
                detail: "_meta.\(MCPMetaKeys.clientCapabilities) is required and must be an object"
            )
        }
        return MCPRequestMeta(
            protocolVersion: version,
            clientInfo: MCPImplementation(json: meta?[MCPMetaKeys.clientInfo]),
            clientCapabilities: MCPClientCapabilities(json: capabilitiesValue),
            progressToken: try progressToken(in: meta),
            traceContext: traceContext(in: meta)
        )
    }

    public static func synthesizedLegacy(
        protocolVersion: MCPProtocolVersion,
        clientInfo: MCPImplementation?,
        clientCapabilities: MCPClientCapabilities,
        params: JsonValue?
    ) throws -> MCPRequestMeta {
        let meta = metaObject(in: params)
        return MCPRequestMeta(
            protocolVersion: protocolVersion,
            clientInfo: clientInfo,
            clientCapabilities: clientCapabilities,
            progressToken: try progressToken(in: meta),
            traceContext: traceContext(in: meta)
        )
    }

    private static func progressToken(in meta: JsonValue?) throws -> MCPProgressToken? {
        guard let value = meta?[MCPMetaKeys.progressToken] else { return nil }
        switch value {
        case .string(let token):
            return .string(token)
        case .int(let token):
            return .number(token)
        case .null:
            return nil
        default:
            throw MCPProtocolError.invalidParams(
                detail: "_meta.progressToken must be a string or an integer"
            )
        }
    }

    private static func traceContext(in meta: JsonValue?) -> [String: String] {
        guard let fields = meta?.objectValue else { return [:] }
        var context: [String: String] = [:]
        for key in MCPMetaKeys.traceContextKeys {
            if let value = fields[key]?.stringValue {
                context[key] = value
            }
        }
        return context
    }
}

public enum MCPProgressToken: Sendable, Equatable, Hashable {
    case string(String)
    case number(Int)

    public var asJsonValue: JsonValue {
        switch self {
        case .string(let value):
            return .string(value)
        case .number(let value):
            return .int(value)
        }
    }
}
