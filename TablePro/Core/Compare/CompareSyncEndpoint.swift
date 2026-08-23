//
//  CompareSyncEndpoint.swift
//  TablePro
//
//  One side of a comparison. The source never changes; the target is written to.
//
//  An endpoint is a `DatabaseScope`, not a connection id. A connection reaches
//  many databases, so identifying a side by connection alone made two databases
//  on one server impossible to compare and left the schema unset, which is how
//  the reads went out unqualified while the writes went out qualified.
//

import Foundation
import TableProPluginKit

internal struct CompareSyncEndpoint: Hashable, Identifiable, Sendable {
    internal let scope: DatabaseScope
    internal let connectionName: String
    internal let databaseType: DatabaseType
    internal let safeModeLevel: SafeModeLevel
    internal let color: ConnectionColor

    internal init(
        scope: DatabaseScope,
        connectionName: String,
        databaseType: DatabaseType,
        safeModeLevel: SafeModeLevel,
        color: ConnectionColor
    ) {
        self.scope = scope
        self.connectionName = connectionName
        self.databaseType = databaseType
        self.safeModeLevel = safeModeLevel
        self.color = color
    }

    internal var id: String {
        "\(scope.connectionId.uuidString)|\(scope.database)|\(scope.schema ?? "")"
    }

    internal var connectionId: UUID { scope.connectionId }
    internal var database: String { scope.database }
    internal var schema: String? { scope.schema }

    internal var canBeWrittenTo: Bool {
        safeModeLevel != .readOnly
    }

    internal var ineligibleAsTargetReason: String? {
        guard !canBeWrittenTo else { return nil }
        return String(localized: "Read-Only. Choose a different connection to write changes to.")
    }

    internal var qualifiedDescription: String {
        var parts = [connectionName]
        if !scope.database.isEmpty { parts.append(scope.database) }
        if let schema = scope.schema, !schema.isEmpty { parts.append(schema) }
        return parts.joined(separator: " / ")
    }

    /// The name shown once the connection is already named elsewhere, so a picker does not repeat it.
    internal var scopeDescription: String {
        guard !scope.database.isEmpty else { return String(localized: "Server") }
        return scope.qualifiedDescription
    }

    internal func withDatabase(_ database: String) -> CompareSyncEndpoint {
        CompareSyncEndpoint(
            scope: DatabaseScope(connectionId: scope.connectionId, database: database, schema: nil),
            connectionName: connectionName,
            databaseType: databaseType,
            safeModeLevel: safeModeLevel,
            color: color
        )
    }

    internal func withSchema(_ schema: String?) -> CompareSyncEndpoint {
        CompareSyncEndpoint(
            scope: DatabaseScope(connectionId: scope.connectionId, database: scope.database, schema: schema),
            connectionName: connectionName,
            databaseType: databaseType,
            safeModeLevel: safeModeLevel,
            color: color
        )
    }
}

internal extension CompareSyncEndpoint {
    static func from(connection: DatabaseConnection, database: String? = nil, schema: String? = nil) -> CompareSyncEndpoint {
        CompareSyncEndpoint(
            scope: DatabaseScope(
                connectionId: connection.id,
                database: database ?? connection.database ?? "",
                schema: schema
            ),
            connectionName: connection.name,
            databaseType: connection.type,
            safeModeLevel: connection.safeModeLevel,
            color: connection.color
        )
    }

    static func candidates(from connections: [DatabaseConnection]) -> [CompareSyncEndpoint] {
        connections.map { from(connection: $0) }
    }
}

internal enum CompareSyncEligibility {
    static func refusalReason(
        for driver: any PluginDatabaseDriver,
        mode: CompareSyncMode,
        endpointName: String
    ) -> String? {
        let required: PluginCapabilities = mode == .structure ? .schemaCompare : .dataCompare
        guard !driver.capabilities.contains(required) else { return nil }
        switch mode {
        case .structure:
            return String(
                format: String(localized: "%@ does not report structure metadata that can be compared."),
                endpointName
            )
        case .data:
            return String(
                format: String(localized: "%@ does not support reading rows in key order, which data compare needs."),
                endpointName
            )
        }
    }
}
