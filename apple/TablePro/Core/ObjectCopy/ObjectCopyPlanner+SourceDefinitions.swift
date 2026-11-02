//
//  ObjectCopyPlanner+SourceDefinitions.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum ObjectCopyDefinitionOutcome: Equatable, Sendable {
    case runnable(String)
    case skipped(String)
}

internal struct ObjectCopyDefinitionInput: Sendable {
    internal let id: String
    internal let identity: CompareObjectIdentity
    internal let definition: String
    internal let read: RoutineSourceRead
    internal let targetCarriesIndexes: Bool
    internal let drop: CompareObjectResult?
}

internal enum ObjectCopyDefinitionBuild: Sendable {
    case built(drop: [SyncStatement], create: [SyncStatement], note: String?)
    case refused(String)
}

internal extension ObjectCopyPlanner {
    nonisolated static func definitionBuild(
        for input: ObjectCopyDefinitionInput,
        using builder: SourceObjectSyncBuilder
    ) throws -> ObjectCopyDefinitionBuild {
        var sourceIndexes: [EditableIndexDefinition]?
        var note: String?
        switch SourceObjectIndexCopy.decide(
            for: input.read, targetCarries: input.targetCarriesIndexes, indexSchema: builder.indexSchema
        ) {
        case .none:
            break
        case .write(let indexes):
            sourceIndexes = indexes
        case .leaveOut(let text):
            note = text
        case .refuse(let reason):
            return .refused(reason)
        }
        let create = CompareObjectResult(
            identity: input.identity,
            status: .onlyInSource,
            sourceDefinition: [input.definition],
            sourceIndexes: sourceIndexes
        )
        let drop = try input.drop.map { existing -> [SyncStatement] in
            guard !builder.replacesInPlace(existing.identity, with: create) else { return [] }
            return try builder.build(for: existing, action: .drop)
        } ?? []
        return .built(drop: drop, create: try builder.build(for: create, action: .create), note: note)
    }

    nonisolated static func definitionOutcome(
        _ read: RoutineSourceRead?,
        sentAs scriptText: SQLScriptText
    ) -> ObjectCopyDefinitionOutcome {
        guard let read else { return .skipped(noDefinition) }
        guard let defect = SourceDefinitionDefect.of(read, sentAs: scriptText) else { return .runnable(read.source) }
        switch defect {
        case .unreadable(let reason):
            return .skipped(reason)
        case .empty:
            return .skipped(noDefinition)
        case .notACreateStatement:
            return .skipped(ObjectCopyEligibility.definitionNotExecutableRefusal)
        case .severalStatements:
            return .skipped(defect.reason(on: .source))
        }
    }

    nonisolated static func sourceDefinitionReads(
        for selections: [ObjectCopySelection],
        views: [TableStructureRead],
        triggerTables: [String],
        schema: String?,
        endpointName: String,
        using plugin: any PluginDatabaseDriver
    ) async throws -> [String: RoutineSourceRead] {
        var reads: [String: RoutineSourceRead] = [:]

        let viewSelections = selections.filter { $0.kind == .view || $0.kind == .materializedView }
        if !viewSelections.isEmpty {
            for read in try await CompareMetadataService.readViewDefinitions(views, schema: schema, using: plugin) {
                guard let selection = viewSelections.first(where: { $0.name.lowercased() == read.name.lowercased() })
                else { continue }
                reads[selection.id] = read
            }
        }

        let routines = selections.filter { $0.kind == .procedure || $0.kind == .function }
        if !routines.isEmpty {
            do {
                for read in try await CompareMetadataService.readRoutineDefinitions(
                    schema: schema, endpointName: endpointName, readsCreationScopes: true, using: plugin
                ) {
                    guard let selection = routines.first(where: {
                        $0.kind == read.kind
                            && $0.name.lowercased() == read.name.lowercased()
                            && ($0.signature ?? "") == (read.signature ?? "")
                    }) else { continue }
                    reads[selection.id] = read
                }
            } catch {
                try reads.merge(listingFailure(error, for: routines), uniquingKeysWith: { _, failed in failed })
            }
        }

        let triggers = selections.filter { $0.kind == .trigger }
        if !triggers.isEmpty {
            do {
                for read in try await CompareMetadataService.readTriggerDefinitions(
                    tables: triggerTables,
                    schema: schema,
                    endpointName: endpointName,
                    readsCreationScopes: true,
                    using: plugin
                ) {
                    guard let selection = triggers.first(where: {
                        $0.name.lowercased() == read.name.lowercased()
                            && ($0.owner.map { $0.lowercased() == (read.signature ?? "").lowercased() } ?? true)
                    }) else { continue }
                    reads[selection.id] = read
                }
            } catch {
                try reads.merge(listingFailure(error, for: triggers), uniquingKeysWith: { _, failed in failed })
            }
        }
        return reads
    }

    /// The source tables a same-engine copy builds its `CREATE TABLE` from, read under the source's
    /// read scope inside the caller's lease: MariaDB renders a TIMESTAMP default in the session's
    /// zone, so the DDL is only right when it is written in the zone it was read in. `isPinned` is
    /// false when the driver has no scope, and the DDL then runs as the session is.
    nonisolated static func pinnedTableReads(
        names: Set<String>,
        schema: String?,
        databaseType: DatabaseType,
        using plugin: any PluginDatabaseDriver
    ) async throws -> (reads: [TableStructureRead], isPinned: Bool) {
        let wanted = Set(names.map { $0.lowercased() })
        let scopes = await VerbatimTransferScopes.open(reading: SessionScopeHandle(plugin))
        do {
            let listed = try await plugin.fetchTables(schema: schema)
            let reads = try await CompareMetadataService.read(
                tables: listed.filter { wanted.contains($0.name.lowercased()) },
                schema: schema,
                profile: .structure,
                narrowed: CompareMetadataService.narrows(listed, to: wanted),
                databaseType: databaseType,
                indexedKinds: SourceObjectIndexes.carriedKinds(on: databaseType),
                using: plugin
            )
            await scopes?.close()
            return (reads, scopes != nil)
        } catch {
            await scopes?.close()
            throw error
        }
    }

    nonisolated private static func listingFailure(
        _ error: Error,
        for selections: [ObjectCopySelection]
    ) throws -> [String: RoutineSourceRead] {
        guard !(error is CancellationError), !Task.isCancelled else { throw CancellationError() }
        let reason = error.localizedDescription
        return Dictionary(
            selections.map { selection in
                (
                    selection.id,
                    RoutineSourceRead(
                        name: selection.name,
                        kind: selection.kind,
                        schema: selection.schema,
                        signature: selection.signature ?? selection.owner,
                        source: "",
                        failure: reason
                    )
                )
            },
            uniquingKeysWith: { first, _ in first }
        )
    }
}
