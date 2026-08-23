//
//  CompareRunner.swift
//  TablePro
//
//  Runs a comparison, builds its script and applies it.
//
//  It owns the I/O so the session does not. Every read goes through
//  `CompareMetadataService` / `CompareRowService`, which route through
//  `DatabaseManager.withMetadataDriver(scope:)`; nothing here reaches
//  `DatabaseManager.driver(for:)`, which hands back the connection's live
//  interactive driver without the gate that keeps it on one database.
//

import Foundation
import os
import TableProPluginKit

@MainActor
internal struct CompareRunner {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "CompareRunner")

    internal let session: CompareSyncSession
    internal let metadataService = CompareMetadataService()
    internal let rowService = CompareRowService()

    internal init(session: CompareSyncSession) {
        self.session = session
    }

    // MARK: - Entry points

    internal func compare() {
        guard session.canCompare else { return }
        session.cancelRunningWork()
        session.errorMessage = nil
        session.informationalMessage = nil

        session.runTask = Task { [session] in
            session.activity = .connecting
            defer { session.activity = .idle }
            do {
                let context = try resolveContext()
                if let refusal = try await capabilityRefusal(context) {
                    session.errorMessage = refusal
                    return
                }
                session.activity = .comparing
                switch session.mode {
                case .structure:
                    try await runStructureCompare(context)
                case .data:
                    try await runDataCompare(context)
                }
                session.informationalMessage = session.crossEngineNotice
            } catch is CancellationError {
                session.informationalMessage = String(localized: "Comparison cancelled.")
            } catch {
                session.errorMessage = error.localizedDescription
            }
        }
    }

    internal func buildScript() {
        guard session.canBuildScript else { return }
        session.cancelRunningWork()
        session.errorMessage = nil

        session.runTask = Task { [session] in
            session.activity = .comparing
            defer { session.activity = .idle }
            do {
                let context = try resolveContext()
                let built: [SyncStatement]
                switch session.mode {
                case .structure:
                    built = try await structureStatements(context)
                case .data:
                    built = try await dataStatements(context)
                }
                guard !built.isEmpty else {
                    session.errorMessage = String(localized: "Nothing is selected to apply.")
                    return
                }
                session.statements = built
                session.detailPane = .script
            } catch is CancellationError {
                session.informationalMessage = String(localized: "Script generation cancelled.")
            } catch {
                session.errorMessage = error.localizedDescription
            }
        }
    }

    internal func apply() {
        guard session.canApply, let target = session.target else { return }
        session.cancelRunningWork()
        session.errorMessage = nil

        let runProgress = Progress(totalUnitCount: Int64(session.statements.count))
        session.progress = runProgress

        session.runTask = Task { [session] in
            session.activity = .applying
            CompareSyncRunRegistry.shared.markApplying(session, target: target.qualifiedDescription)
            defer {
                session.activity = .idle
                session.progress = nil
                CompareSyncRunRegistry.shared.clear(session)
            }

            do {
                /// Resolved for its validation: it throws when a connection has gone away, which
                /// must stop the run before anything is written.
                _ = try resolveContext()
                let statements = session.statements
                let settings = session.executionSettings
                let mode = session.mode
                let result = try await DatabaseManager.shared.withMetadataDriver(scope: target.scope) { driver in
                    guard let plugin = CompareMetadataService.pluginDriver(from: driver) else {
                        throw CompareSyncError.unsupportedOperation(
                            String(localized: "The target driver cannot run a sync script.")
                        )
                    }
                    return try await CompareSyncExecutor().apply(
                        statements: statements,
                        mode: mode,
                        settings: settings,
                        target: target,
                        driver: plugin,
                        progress: runProgress
                    )
                }
                /// Set from the result, not before the run. Setting it up front meant a declined
                /// authorization or a driver that could not run the script still flipped the status
                /// strip to "written", next to text that still read "Nothing has been written."
                session.hasWrittenToTarget = session.hasWrittenToTarget || result.executedCount > 0
                session.runResult = result
                session.lastAction = .applied(
                    Date(), target: target.qualifiedDescription, statements: result.executedCount
                )
                /// The script just ran, so it describes work the target has already had. Leaving it
                /// armed left Apply enabled on a stale plan, one click from running the same
                /// CREATE/ALTER/DELETE a second time.
                session.markAppliedAndStale()
            } catch {
                session.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Context

    internal struct Context {
        internal let source: CompareSyncEndpoint
        internal let target: CompareSyncEndpoint
        internal let sourceConnection: DatabaseConnection
        internal let targetConnection: DatabaseConnection
    }

    internal func resolveContext() throws -> Context {
        guard let source = session.source, let target = session.target else {
            throw CompareSyncError.unsupportedOperation(String(localized: "Choose a source and a target first."))
        }
        let connections = ConnectionStorage.shared.loadConnections()
        guard let sourceConnection = connections.first(where: { $0.id == source.connectionId }) else {
            throw CompareSyncError.unsupportedOperation(missingConnection(source))
        }
        guard let targetConnection = connections.first(where: { $0.id == target.connectionId }) else {
            throw CompareSyncError.unsupportedOperation(missingConnection(target))
        }
        return Context(
            source: source, target: target,
            sourceConnection: sourceConnection, targetConnection: targetConnection
        )
    }

    private func missingConnection(_ endpoint: CompareSyncEndpoint) -> String {
        String(
            format: String(localized: "%@ is no longer a saved connection."),
            endpoint.connectionName
        )
    }

    private func capabilityRefusal(_ context: Context) async throws -> String? {
        if let refusal = try await metadataService.refusalReason(
            for: context.source, connection: context.sourceConnection, mode: session.mode
        ) {
            return refusal
        }
        return try await metadataService.refusalReason(
            for: context.target, connection: context.targetConnection, mode: session.mode
        )
    }

    // MARK: - Structure

    private func runStructureCompare(_ context: Context) async throws {
        let wantsViews = session.includedKinds.contains(.view)
            || session.includedKinds.contains(.materializedView)

        let sourceReads = try await metadataService.tableReads(
            for: context.source, connection: context.sourceConnection, includeViews: wantsViews
        )
        try Task.checkCancellation()
        let targetReads = try await metadataService.tableReads(
            for: context.target, connection: context.targetConnection, includeViews: wantsViews
        )
        try Task.checkCancellation()

        let sourceTables = sourceReads.filter { CompareTableKindClassifier.kind(of: $0.table) == .table }
        let targetTables = targetReads.filter { CompareTableKindClassifier.kind(of: $0.table) == .table }

        let sourceSnapshots = sourceTables.compactMap { $0.snapshot }
        let targetSnapshots = targetTables.compactMap { $0.snapshot }

        let engine = StructureDiffEngine(options: session.structureOptions)
        let tableReport = engine.compare(source: sourceSnapshots, target: targetSnapshots)

        session.sourceSnapshots = Dictionary(
            sourceSnapshots.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first }
        )
        session.targetSnapshots = Dictionary(
            targetSnapshots.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first }
        )

        var results = tableReport.results.map { result -> CompareObjectResult in
            CompareObjectResult.from(
                result,
                sourceDefinition: session.sourceSnapshots[result.id].map(TableDefinitionRenderer.lines) ?? [],
                targetDefinition: session.targetSnapshots[result.id].map(TableDefinitionRenderer.lines) ?? []
            )
        }
        results += unreadableResults(sourceTables, targetTables)
        results += try await sourceDefinedResults(context, sourceReads: sourceReads, targetReads: targetReads)

        let report = CompareReport(results: results)
        session.report = report
        session.actions = [:]
        for result in report.comparable where session.pendingSelection.contains(result.id) {
            session.actions[result.id] = result.suggestedAction
        }
        session.pendingSelection = []
        session.invalidateScript()
        session.selectedObjectId = session.visibleResults.first?.id
        session.lastAction = .compared(Date(), differences: report.differenceCount)
    }

    /// A table whose metadata could not be read is listed with its reason rather than aborting the
    /// comparison, which is what `CompareObjectResult.comparisonError` is for. Before this, one
    /// unreadable table threw and the user saw no results at all.
    private func unreadableResults(
        _ sourceTables: [TableStructureRead],
        _ targetTables: [TableStructureRead]
    ) -> [CompareObjectResult] {
        var seen: Set<String> = []
        var results: [CompareObjectResult] = []
        for read in sourceTables + targetTables {
            guard let failure = read.failure else { continue }
            let identity = CompareObjectIdentity(kind: .table, schema: read.table.schema, name: read.table.name)
            guard seen.insert(identity.id).inserted else { continue }
            results.append(CompareObjectResult(
                identity: identity, status: .differs, comparisonError: failure
            ))
        }
        return results
    }

    private func sourceDefinedResults(
        _ context: Context,
        sourceReads: [TableStructureRead],
        targetReads: [TableStructureRead]
    ) async throws -> [CompareObjectResult] {
        var results: [CompareObjectResult] = []

        if session.includedKinds.contains(.view) || session.includedKinds.contains(.materializedView) {
            let sourceViews = sourceReads.map(\.table).filter { CompareTableKindClassifier.kind(of: $0) != .table }
            let targetViews = targetReads.map(\.table).filter { CompareTableKindClassifier.kind(of: $0) != .table }
            let sourceDefinitions = try await metadataService.viewDefinitions(
                for: context.source, connection: context.sourceConnection, views: sourceViews
            )
            let targetDefinitions = try await metadataService.viewDefinitions(
                for: context.target, connection: context.targetConnection, views: targetViews
            )
            results += SourceObjectDiffEngine(options: session.structureOptions)
                .compare(source: sourceDefinitions, target: targetDefinitions)
        }

        if session.includedKinds.contains(.procedure) || session.includedKinds.contains(.function) {
            let sourceRoutines = try await metadataService.routineReads(
                for: context.source, connection: context.sourceConnection
            )
            let targetRoutines = try await metadataService.routineReads(
                for: context.target, connection: context.targetConnection
            )
            results += SourceObjectDiffEngine(options: session.structureOptions)
                .compare(source: sourceRoutines, target: targetRoutines)
                .filter { session.includedKinds.contains($0.identity.kind) }
        }

        if session.includedKinds.contains(.trigger) {
            let sourceTriggers = try await metadataService.triggerReads(
                for: context.source,
                connection: context.sourceConnection,
                tables: sourceReads.map(\.table.name)
            )
            let targetTriggers = try await metadataService.triggerReads(
                for: context.target,
                connection: context.targetConnection,
                tables: targetReads.map(\.table.name)
            )
            results += SourceObjectDiffEngine(options: session.structureOptions)
                .compare(source: sourceTriggers, target: targetTriggers)
        }

        return results
    }

    private func structureStatements(_ context: Context) async throws -> [SyncStatement] {
        guard let report = session.report else { return [] }
        let snapshots = session.sourceSnapshots
        let selected = report.comparable.filter { session.action(for: $0) != .skip }
        let tableOperations = selected.compactMap { result -> SchemaSyncOperation? in
            guard result.identity.kind == .table else { return nil }
            switch session.action(for: result) {
            case .skip: return nil
            case .create:
                guard let snapshot = snapshots[result.identity.qualifiedName] else { return nil }
                return .createTable(snapshot)
            case .drop:
                return .dropTable(name: result.identity.name, schema: result.identity.schema)
            case .alter:
                guard !result.changes.isEmpty else { return nil }
                return .alterTable(
                    name: result.identity.name, schema: result.identity.schema, changes: result.changes
                )
            }
        }
        /// The action is resolved before the closure, because the closure crosses an isolation
        /// boundary and the session is main-actor state.
        let sourceDefined = selected
            .filter { $0.identity.kind != .table }
            .map { (result: $0, action: session.action(for: $0)) }
        let foreignKeys = Self.foreignKeyMap(from: snapshots)

        return try await DatabaseManager.shared.withMetadataDriver(scope: context.target.scope) { driver in
            guard let plugin = CompareMetadataService.pluginDriver(from: driver) else {
                throw CompareSyncError.unsupportedOperation(
                    String(localized: "The target driver cannot generate a sync script.")
                )
            }
            var statements = try SchemaSyncScriptBuilder(targetDriver: plugin)
                .build(operations: tableOperations, foreignKeysByTable: foreignKeys)
            let sourceBuilder = SourceObjectSyncBuilder(targetDriver: plugin)
            for entry in sourceDefined {
                statements += sourceBuilder.build(for: entry.result, action: entry.action)
            }
            return statements
        }
    }

    internal static func foreignKeyMap(
        from snapshots: [String: TableStructureSnapshot]
    ) -> [String: [PluginForeignKeyInfo]] {
        var map: [String: [PluginForeignKeyInfo]] = [:]
        for snapshot in snapshots.values {
            let dependencies = snapshot.foreignKeys.compactMap { foreignKey -> PluginForeignKeyInfo? in
                guard let column = foreignKey.columns.first,
                      let referencedColumn = foreignKey.referencedColumns.first else { return nil }
                let referencedSchema = foreignKey.referencedSchema ?? snapshot.schema
                /// The sort qualifies `referencedTable` with `referencedSchema` itself, so
                /// pre-qualifying here produced `public.public.orders` and dropped every edge.
                return PluginForeignKeyInfo(
                    name: foreignKey.name,
                    column: column,
                    referencedTable: foreignKey.referencedTable,
                    referencedColumn: referencedColumn,
                    referencedSchema: referencedSchema
                )
            }
            guard !dependencies.isEmpty else { continue }
            map[snapshot.qualifiedName] = dependencies
        }
        return map
    }
}
