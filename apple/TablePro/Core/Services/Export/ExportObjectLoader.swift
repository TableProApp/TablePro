//
//  ExportObjectLoader.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

// A kind the driver cannot answer comes back empty: one engine without routines must not cost the user their table list.
internal enum ExportObjectLoader {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportObjectLoader")

    internal static let loadableKinds: Set<PluginExportObjectKind> = [
        .table, .view, .materializedView, .foreignTable,
        .routine, .trigger, .event, .sequence, .userType, .grant
    ]

    internal struct Request: Sendable {
        internal let containerName: String
        internal let schema: String?
        internal let kinds: Set<PluginExportObjectKind>

        internal init(containerName: String, schema: String?, kinds: Set<PluginExportObjectKind>) {
            self.containerName = containerName
            self.schema = schema
            self.kinds = kinds
        }
    }

    internal static func loadObjects(
        request: Request,
        tables: [TableInfo],
        driver: DatabaseDriver
    ) async -> [ExportObjectItem] {
        var items = tables.compactMap { table -> ExportObjectItem? in
            let kind = PluginExportObjectKind.from(tableType: table.type.rawValue)
            guard request.kinds.contains(kind) else { return nil }
            // A sequence holds no rows worth a file, and a role with USAGE alone cannot read it.
            if table.type == .sequence, !request.kinds.contains(.sequence) { return nil }
            return ExportObjectItem(name: table.name, databaseName: request.containerName, kind: kind)
        }

        guard let pluginDriver = driver.plugin else { return items }

        if request.kinds.contains(.routine) {
            items += await loadRoutines(schema: request.schema, container: request.containerName, driver: pluginDriver)
        }
        if request.kinds.contains(.trigger) {
            items += await loadTriggers(schema: request.schema, container: request.containerName, driver: pluginDriver)
        }
        if request.kinds.contains(.event) {
            items += await loadEvents(schema: request.schema, container: request.containerName, driver: pluginDriver)
        }
        if request.kinds.contains(.sequence) {
            let sequences = await loadSequences(schema: request.schema, container: request.containerName, driver: pluginDriver)
            // The table listing reported these as tables too; one relation, written once as a sequence.
            let listedAsSequences = Set(sequences.map(\.name))
            items.removeAll { $0.kind == .table && listedAsSequences.contains($0.name) }
            items += sequences
        }
        if request.kinds.contains(.userType) {
            items += await loadUserTypes(schema: request.schema, container: request.containerName, driver: pluginDriver)
        }
        if request.kinds.contains(.grant) {
            items += await loadPrincipals(container: request.containerName, driver: pluginDriver)
        }
        return items
    }

    private static func loadRoutines(
        schema: String?,
        container: String,
        driver: any PluginDatabaseDriver
    ) async -> [ExportObjectItem] {
        do {
            return try await driver.fetchRoutines(schema: schema).map { routine in
                ExportObjectItem(
                    name: routine.name,
                    databaseName: container,
                    kind: .routine,
                    identity: routine.argumentSignature,
                    routineKind: routine.kind
                )
            }
        } catch {
            logger.warning("Failed to list routines for export: \(error.localizedDescription)")
            return []
        }
    }

    // Not gated on `providesBulkTriggerFetch`: that is Compare's scope rule, and Oracle answers this list with it false.
    // A driver without a schema-wide list answers empty without a read, and none is asked per table.
    private static func loadTriggers(
        schema: String?,
        container: String,
        driver: any PluginDatabaseDriver
    ) async -> [ExportObjectItem] {
        do {
            return try await driver.fetchAllTriggers(schema: schema).map { trigger in
                ExportObjectItem(
                    name: trigger.name,
                    databaseName: container,
                    kind: .trigger,
                    parentTable: trigger.table
                )
            }
        } catch {
            logger.warning("Failed to list triggers for export: \(error.localizedDescription)")
            return []
        }
    }

    private static func loadEvents(
        schema: String?,
        container: String,
        driver: any PluginDatabaseDriver
    ) async -> [ExportObjectItem] {
        do {
            return try await driver.fetchEvents(schema: schema).map { event in
                ExportObjectItem(name: event.name, databaseName: container, kind: .event)
            }
        } catch {
            logger.warning("Failed to list events for export: \(error.localizedDescription)")
            return []
        }
    }

    // Includes sequences a table owns; the SQL export writes a name reached twice only once.
    private static func loadSequences(
        schema: String?,
        container: String,
        driver: any PluginDatabaseDriver
    ) async -> [ExportObjectItem] {
        do {
            return try await driver.fetchSequences(schema: schema).map { sequence in
                ExportObjectItem(name: sequence.name, databaseName: container, kind: .sequence)
            }
        } catch {
            logger.warning("Failed to list sequences for export: \(error.localizedDescription)")
            return []
        }
    }

    private static func loadUserTypes(
        schema: String?,
        container: String,
        driver: any PluginDatabaseDriver
    ) async -> [ExportObjectItem] {
        do {
            return try await driver.fetchUserDefinedTypes(schema: schema).map { type in
                ExportObjectItem(name: type.name, databaseName: container, kind: .userType)
            }
        } catch {
            logger.warning("Failed to list user-defined types for export: \(error.localizedDescription)")
            return []
        }
    }

    // Principals are server-wide, so they are listed only under the container the dialog opened on.
    private static func loadPrincipals(
        container: String,
        driver: any PluginDatabaseDriver
    ) async -> [ExportObjectItem] {
        guard let management = driver as? any PluginPrincipalManagement else { return [] }
        do {
            return try await management.fetchPrincipals().map { principal in
                ExportObjectItem(
                    name: principal.ref.name,
                    databaseName: container,
                    kind: .grant,
                    identity: principal.ref.host
                )
            }
        } catch {
            logger.warning("Failed to list principals for export: \(error.localizedDescription)")
            return []
        }
    }
}
