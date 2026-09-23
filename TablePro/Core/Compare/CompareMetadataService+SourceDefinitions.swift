//
//  CompareMetadataService+SourceDefinitions.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit
import TableProSQLGrammar

internal struct RoutineSourceRead: Sendable {
    internal let name: String
    internal let kind: CompareObjectKind
    internal let schema: String?
    internal let signature: String?
    internal let source: String
    internal let failure: String?

    internal init(
        name: String,
        kind: CompareObjectKind,
        schema: String?,
        signature: String?,
        source: String,
        failure: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.schema = schema
        self.signature = signature
        self.source = source
        self.failure = failure
    }
}

internal extension CompareMetadataService {
    nonisolated private static let definitionLogger = Logger(
        subsystem: "com.TablePro", category: "CompareMetadataService"
    )

    nonisolated static func readViewDefinitions(
        _ views: [PluginTableInfo],
        schema: String?,
        using plugin: any PluginDatabaseDriver
    ) async throws -> [RoutineSourceRead] {
        var reads: [RoutineSourceRead] = []
        for view in views {
            try Task.checkCancellation()
            let viewSchema = view.schema ?? schema
            reads.append(try await definitionRead(
                name: view.name,
                kind: CompareTableKindClassifier.kind(of: view),
                schema: viewSchema,
                signature: nil
            ) {
                try await plugin.fetchViewDefinition(view: view.name, schema: viewSchema)
            })
        }
        return reads
    }

    nonisolated static func readRoutineDefinitions(
        schema: String?,
        endpointName: String,
        using plugin: any PluginDatabaseDriver
    ) async throws -> [RoutineSourceRead] {
        let routines: [PluginRoutineInfo]
        do {
            routines = try await plugin.fetchRoutines(schema: schema)
        } catch {
            throw listingFailure(error, message: String(
                format: String(localized: "The procedures and functions in %1$@ could not be listed: %2$@"),
                endpointName, error.localizedDescription
            ))
        }
        var reads: [RoutineSourceRead] = []
        for routine in routines {
            try Task.checkCancellation()
            reads.append(try await definitionRead(
                name: routine.name,
                kind: routine.kind == .procedure ? .procedure : .function,
                schema: routine.schema ?? schema,
                signature: routine.argumentSignature
            ) {
                try await plugin.fetchRoutineDDL(routine)
            })
        }
        return reads
    }

    nonisolated static func readTriggerDefinitions(
        tables: [String],
        schema: String?,
        endpointName: String,
        using plugin: any PluginDatabaseDriver
    ) async throws -> [RoutineSourceRead] {
        let listed = try await listTriggers(tables: tables, schema: schema, endpointName: endpointName, using: plugin)
        var reads: [RoutineSourceRead] = []
        for (trigger, owningTable) in listed {
            try Task.checkCancellation()
            reads.append(try await definitionRead(
                name: trigger.name,
                kind: .trigger,
                schema: trigger.schema ?? schema,
                signature: trigger.table ?? owningTable
            ) {
                if let definition = trigger.definition, StatementBlank.hasContent(definition) {
                    return definition
                }
                return try await plugin.fetchTriggerDDL(trigger)
            })
        }
        return reads
    }

    nonisolated private static func listTriggers(
        tables: [String],
        schema: String?,
        endpointName: String,
        using plugin: any PluginDatabaseDriver
    ) async throws -> [(trigger: PluginTriggerInfo, owningTable: String?)] {
        guard plugin.providesBulkTriggerFetch else {
            return try await listTriggersPerTable(tables, schema: schema, endpointName: endpointName, using: plugin)
        }
        let triggers: [PluginTriggerInfo]
        do {
            triggers = try await plugin.fetchAllTriggers(schema: schema)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            definitionLogger.warning(
                "Whole-schema trigger read failed, falling back per table: \(error.publicLogShape, privacy: .public)"
            )
            return try await listTriggersPerTable(tables, schema: schema, endpointName: endpointName, using: plugin)
        }
        let inScope = Set(tables.map { $0.lowercased() })
        return triggers
            .filter { trigger in
                guard let table = trigger.table?.lowercased() else { return true }
                return inScope.contains(table)
            }
            .map { (trigger: $0, owningTable: nil) }
    }

    nonisolated private static func listTriggersPerTable(
        _ tables: [String],
        schema: String?,
        endpointName: String,
        using plugin: any PluginDatabaseDriver
    ) async throws -> [(trigger: PluginTriggerInfo, owningTable: String?)] {
        var listed: [(trigger: PluginTriggerInfo, owningTable: String?)] = []
        for table in tables {
            try Task.checkCancellation()
            do {
                listed += try await plugin.fetchTriggers(table: table, schema: schema)
                    .map { (trigger: $0, owningTable: table) }
            } catch {
                throw listingFailure(error, message: String(
                    format: String(localized: "The triggers on %1$@ in %2$@ could not be listed: %3$@"),
                    table, endpointName, error.localizedDescription
                ))
            }
        }
        return listed
    }

    nonisolated private static func listingFailure(_ error: Error, message: String) -> Error {
        guard !(error is CancellationError), !Task.isCancelled else { return CancellationError() }
        definitionLogger.warning("Definition listing failed: \(error.publicLogShape, privacy: .public)")
        return CompareSyncError.readFailed(message)
    }

    nonisolated private static func definitionRead(
        name: String,
        kind: CompareObjectKind,
        schema: String?,
        signature: String?,
        reading: () async throws -> String
    ) async throws -> RoutineSourceRead {
        do {
            let source = try await reading()
            return RoutineSourceRead(name: name, kind: kind, schema: schema, signature: signature, source: source)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { throw CancellationError() }
            definitionLogger.warning(
                "Definition read failed for \(kind.rawValue, privacy: .public) \(name, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)"
            )
            return RoutineSourceRead(
                name: name, kind: kind, schema: schema, signature: signature,
                source: "", failure: error.localizedDescription
            )
        }
    }
}
