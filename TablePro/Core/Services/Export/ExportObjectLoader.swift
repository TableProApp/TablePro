//
//  ExportObjectLoader.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// Everything one container of the export tree can offer, read from the driver.
///
/// The export dialog asks per container, and only for the kinds the chosen format says it can
/// write, so picking CSV never pays for a routine list nobody will export. A kind the driver
/// cannot answer comes back empty rather than failing the load: one engine without routines must
/// not cost the user their table list.
internal enum ExportObjectLoader {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ExportObjectLoader")

    /// The kinds this loader knows how to read. A driver that has no answer for one returns empty,
    /// so a kind listed here costs nothing on an engine that lacks it.
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
            return ExportObjectItem(name: table.name, databaseName: request.containerName, kind: kind)
        }

        guard let pluginDriver = (driver as? PluginDriverAdapter)?.schemaPluginDriver else { return items }

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
            items += await loadSequences(schema: request.schema, container: request.containerName, driver: pluginDriver)
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
                    identity: routine.argumentSignature
                )
            }
        } catch {
            logger.warning("Failed to list routines for export: \(error.localizedDescription)")
            return []
        }
    }

    /// Only a driver that answers a schema-wide trigger list is asked. Falling back to a read per
    /// table would be one round trip per table just to fill a tree the user may never open.
    private static func loadTriggers(
        schema: String?,
        container: String,
        driver: any PluginDatabaseDriver
    ) async -> [ExportObjectItem] {
        guard driver.providesBulkTriggerFetch else { return [] }
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

    /// Every sequence in the container, including the ones a table already owns. The SQL export
    /// emits each name once, so a sequence reached by both this list and `fetchDependentSequences`
    /// is written a single time.
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

    /// Principals are server-wide rather than per container, so they are listed only under the
    /// container the dialog opened on. Listing them under every schema would offer the same GRANT
    /// statements several times over.
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
