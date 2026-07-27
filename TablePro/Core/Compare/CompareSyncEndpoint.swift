//
//  CompareSyncEndpoint.swift
//  TablePro
//
//  One side of a comparison. The source never changes; the target is written to.
//

import Foundation
import TableProPluginKit

internal struct CompareSyncEndpoint: Hashable, Identifiable {
    internal let connectionId: UUID
    internal let displayName: String
    internal let databaseType: DatabaseType
    internal let database: String?
    internal let schema: String?
    internal let safeModeLevel: SafeModeLevel
    internal let color: ConnectionColor

    internal var id: String {
        "\(connectionId.uuidString)-\(database ?? "")-\(schema ?? "")"
    }

    internal var canBeWrittenTo: Bool {
        safeModeLevel != .readOnly
    }

    internal var ineligibleAsTargetReason: String? {
        guard !canBeWrittenTo else { return nil }
        return String(localized: "Read-Only. Choose a different connection to write changes to.")
    }

    internal var qualifiedDescription: String {
        var parts = [displayName]
        if let database, !database.isEmpty { parts.append(database) }
        if let schema, !schema.isEmpty { parts.append(schema) }
        return parts.joined(separator: " / ")
    }
}

internal extension CompareSyncEndpoint {
    static func candidates(from connections: [DatabaseConnection]) -> [CompareSyncEndpoint] {
        connections.map { connection in
            CompareSyncEndpoint(
                connectionId: connection.id,
                displayName: connection.name,
                databaseType: connection.type,
                database: connection.database,
                schema: nil,
                safeModeLevel: connection.safeModeLevel,
                color: connection.color
            )
        }
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
