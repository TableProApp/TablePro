//
//  MCPResourceHandler.swift
//  TablePro
//

import Foundation
import os

final class MCPResourceHandler: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCPResourceHandler")

    private let bridge: MCPConnectionBridge

    init(bridge: MCPConnectionBridge) {
        self.bridge = bridge
    }

    // MARK: - Dispatch

    func handleResourceRead(uri: String, sessionId: String) async throws -> MCPResourceReadResult {
        guard let components = URLComponents(string: uri) else {
            throw MCPError.invalidParams("Malformed URI: \(uri)")
        }

        guard components.scheme == "tablepro" else {
            throw MCPError.invalidParams("Unsupported URI scheme: \(components.scheme ?? "nil")")
        }

        let pathSegments = parsePathSegments(from: uri)

        if pathSegments == ["connections"] {
            return try await handleConnectionsList(uri: uri)
        }

        if pathSegments.count == 3,
           pathSegments[0] == "connections",
           pathSegments[2] == "schema"
        {
            guard let connectionId = UUID(uuidString: pathSegments[1]) else {
                throw MCPError.invalidParams("Invalid connection UUID in URI")
            }
            return try await handleSchemaResource(uri: uri, connectionId: connectionId)
        }

        if pathSegments.count == 3,
           pathSegments[0] == "connections",
           pathSegments[2] == "history"
        {
            guard let connectionId = UUID(uuidString: pathSegments[1]) else {
                throw MCPError.invalidParams("Invalid connection UUID in URI")
            }
            let queryItems = components.queryItems ?? []
            return try await handleHistoryResource(uri: uri, connectionId: connectionId, queryItems: queryItems)
        }

        throw MCPError.invalidParams("Unknown resource URI: \(uri)")
    }

    // MARK: - Resource Handlers

    private func handleConnectionsList(uri: String) async throws -> MCPResourceReadResult {
        let result = await bridge.listConnections()
        let jsonString = encodeJSON(result)
        return MCPResourceReadResult(contents: [
            MCPResourceContent(uri: uri, mimeType: "application/json", text: jsonString)
        ])
    }

    private func handleSchemaResource(uri: String, connectionId: UUID) async throws -> MCPResourceReadResult {
        let result = try await bridge.fetchSchemaResource(connectionId: connectionId)
        let jsonString = encodeJSON(result)
        return MCPResourceReadResult(contents: [
            MCPResourceContent(uri: uri, mimeType: "application/json", text: jsonString)
        ])
    }

    private func handleHistoryResource(
        uri: String,
        connectionId: UUID,
        queryItems: [URLQueryItem]
    ) async throws -> MCPResourceReadResult {
        let limit = queryItems.first(where: { $0.name == "limit" })
            .flatMap { $0.value }
            .flatMap { Int($0) }
            ?? 50

        let clampedLimit = min(max(limit, 1), 500)
        let search = queryItems.first(where: { $0.name == "search" })?.value
        let dateFilter = queryItems.first(where: { $0.name == "date_filter" })?.value

        let result = try await bridge.fetchHistoryResource(
            connectionId: connectionId,
            limit: clampedLimit,
            search: search,
            dateFilter: dateFilter
        )
        let jsonString = encodeJSON(result)
        return MCPResourceReadResult(contents: [
            MCPResourceContent(uri: uri, mimeType: "application/json", text: jsonString)
        ])
    }

    // MARK: - Helpers

    private func parsePathSegments(from uri: String) -> [String] {
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

    private func encodeJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8)
        else {
            Self.logger.warning("Failed to encode JSON value")
            return "{}"
        }
        return string
    }
}
