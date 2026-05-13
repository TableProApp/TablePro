import Foundation
import os

public struct ResourcesReadHandler: MCPMethodHandler {
    public static let method = "resources/read"
    public static let requiredScopes: Set<MCPScope> = [.resourcesRead]
    public static let allowedSessionStates: Set<MCPSessionAllowedState> = [.ready]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Resources")

    private let services: MCPToolServices

    public init(services: MCPToolServices) {
        self.services = services
    }

    public func handle(params: JsonValue?, context: MCPRequestContext) async throws -> JsonRpcMessage {
        guard case .string(let uri)? = params?["uri"] else {
            throw MCPProtocolError.invalidParams(detail: "Missing required parameter: uri")
        }

        do {
            let route = try Self.parseRoute(uri: uri)
            let payload = try await Self.fetchPayload(for: route, services: services)
            let text = Self.encodeJsonString(payload)

            let result: JsonValue = .object([
                "contents": .array([
                    .object([
                        "uri": .string(uri),
                        "mimeType": .string("application/json"),
                        "text": .string(text)
                    ])
                ])
            ])

            Self.logger.debug("resources/read uri=\(uri, privacy: .public)")
            MCPAuditLogger.logResourceRead(
                tokenId: nil,
                tokenName: context.principal.metadata.label,
                uri: uri,
                outcome: .success
            )
            return MCPMethodHandlerHelpers.successResponse(id: context.requestId, result: result)
        } catch {
            MCPAuditLogger.logResourceRead(
                tokenId: nil,
                tokenName: context.principal.metadata.label,
                uri: uri,
                outcome: .error,
                errorMessage: (error as? MCPProtocolError)?.message ?? error.localizedDescription
            )
            throw error
        }
    }

    private enum ResourceRoute {
        case connectionsList
        case connectionSchema(connectionId: UUID)
        case connectionHistory(connectionId: UUID, limit: Int, search: String?, dateFilter: String?)
    }

    private static func parseRoute(uri: String) throws -> ResourceRoute {
        guard let components = URLComponents(string: uri) else {
            throw MCPProtocolError.invalidParams(detail: "Malformed URI: \(uri)")
        }
        guard components.scheme == "tablepro" else {
            throw MCPProtocolError.invalidParams(detail: "Unsupported URI scheme: \(components.scheme ?? "nil")")
        }

        let segments = pathSegments(from: uri)

        if segments == ["connections"] {
            return .connectionsList
        }

        guard segments.count == 3, segments[0] == "connections" else {
            throw MCPProtocolError(
                code: JsonRpcErrorCode.methodNotFound,
                message: "Unknown resource URI: \(uri)",
                httpStatus: .notFound
            )
        }

        guard let connectionId = UUID(uuidString: segments[1]) else {
            throw MCPProtocolError.invalidParams(detail: "Invalid connection UUID in URI")
        }

        switch segments[2] {
        case "schema":
            return .connectionSchema(connectionId: connectionId)
        case "history":
            let queryItems = components.queryItems ?? []
            let rawLimit = queryItems.first(where: { $0.name == "limit" })?.value.flatMap { Int($0) } ?? 50
            let limit = min(max(rawLimit, 1), 500)
            let search = queryItems.first(where: { $0.name == "search" })?.value
            let dateFilter = queryItems.first(where: { $0.name == "date_filter" })?.value
            return .connectionHistory(
                connectionId: connectionId,
                limit: limit,
                search: search,
                dateFilter: dateFilter
            )
        default:
            throw MCPProtocolError(
                code: JsonRpcErrorCode.methodNotFound,
                message: "Unknown resource URI: \(uri)",
                httpStatus: .notFound
            )
        }
    }

    private static func fetchPayload(for route: ResourceRoute, services: MCPToolServices) async throws -> JsonValue {
        switch route {
        case .connectionsList:
            return await services.connectionBridge.listConnections()

        case .connectionSchema(let connectionId):
            do {
                return try await services.connectionBridge.fetchSchemaResource(connectionId: connectionId)
            } catch let error as MCPDataLayerError {
                throw mapDomainError(error)
            }

        case .connectionHistory(let connectionId, let limit, let search, let dateFilter):
            do {
                return try await services.connectionBridge.fetchHistoryResource(
                    connectionId: connectionId,
                    limit: limit,
                    search: search,
                    dateFilter: dateFilter
                )
            } catch let error as MCPDataLayerError {
                throw mapDomainError(error)
            }
        }
    }

    private static func mapDomainError(_ error: MCPDataLayerError) -> MCPProtocolError {
        switch error {
        case .invalidArgument(let detail):
            return MCPProtocolError.invalidParams(detail: detail)
        case .notConnected(let id):
            return MCPProtocolError.invalidParams(detail: "Connection not active: \(id.uuidString)")
        case .forbidden(let reason, _):
            return MCPProtocolError.forbidden(reason: reason)
        case .notFound(let detail):
            return MCPProtocolError(
                code: JsonRpcErrorCode.resourceNotFound,
                message: detail,
                httpStatus: .notFound
            )
        case .expired(let detail):
            return MCPProtocolError(
                code: JsonRpcErrorCode.expired,
                message: detail,
                httpStatus: .ok
            )
        case .timeout(let detail, _):
            return MCPProtocolError(
                code: JsonRpcErrorCode.requestTimeout,
                message: "Timeout: \(detail)",
                httpStatus: .ok
            )
        case .userCancelled:
            return MCPProtocolError(
                code: JsonRpcErrorCode.requestCancelled,
                message: "User cancelled",
                httpStatus: .ok
            )
        case .dataSourceError(let detail):
            return MCPProtocolError.internalError(detail: detail)
        }
    }

    private static func pathSegments(from uri: String) -> [String] {
        guard let range = uri.range(of: "://") else { return [] }
        let afterScheme = String(uri[range.upperBound...])
        let pathOnly: String
        if let queryStart = afterScheme.firstIndex(of: "?") {
            pathOnly = String(afterScheme[..<queryStart])
        } else {
            pathOnly = afterScheme
        }
        return pathOnly.split(separator: "/").map(String.init)
    }

    private static func encodeJsonString(_ value: JsonValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
