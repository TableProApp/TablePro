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

        let claim = session.currentClaim
        session.runTask = Task { [session] in
            session.activity = .connecting
            defer { session.activity = .idle }
            do {
                let context = try resolveContext()
                if let refusal = try await capabilityRefusal(context) {
                    guard session.ownsAnswer(claim) else { return }
                    session.errorMessage = refusal
                    return
                }
                session.activity = .comparing
                switch claim.mode {
                case .structure:
                    try await runStructureCompare(context, claim: claim)
                case .data:
                    try await runDataCompare(context, claim: claim)
                }
                guard session.ownsAnswer(claim) else { return }
                session.informationalMessage = session.crossEngineNotice
            } catch is CancellationError {
            } catch {
                guard session.ownsAnswer(claim) else { return }
                session.errorMessage = error.localizedDescription
            }
        }
    }

    internal func buildScript() {
        guard let task = makeScriptTask() else { return }
        session.runTask = task
    }

    /// Builds the script and waits, for the caller that needs one before it can show anything.
    /// Apply takes this route, so a comparison is one press away from the sheet that reviews it
    /// rather than two.
    internal func buildScriptIfNeeded() async -> Bool {
        guard session.statements.isEmpty else { return true }
        guard let task = makeScriptTask() else { return false }
        /// Read after `makeScriptTask`, because cancelling the previous run advances the revision.
        let claim = session.currentClaim
        session.runTask = task
        await task.value
        return session.owns(claim) && !session.statements.isEmpty
    }

    private func makeScriptTask() -> Task<Void, Never>? {
        guard session.canBuildScript else { return nil }
        session.cancelRunningWork()
        session.errorMessage = nil

        let claim = session.currentClaim
        return Task { [session] in
            session.activity = .buildingScript
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
                try Task.checkCancellation()
                /// A script describes one setup and one set of choices. Committing it after either
                /// moved would arm Apply with statements for a database the window no longer names,
                /// or for an object the user has just excluded.
                guard session.owns(claim) else { return }
                guard !built.isEmpty else {
                    session.errorMessage = String(localized: "Nothing is selected to apply.")
                    return
                }
                session.statements = built
                session.detailPane = .script
            } catch is CancellationError {
            } catch {
                /// The full claim, not the answer alone: a build that failed for a selection the
                /// user has since changed would blame an object they had just excluded.
                guard session.owns(claim) else { return }
                session.errorMessage = error.localizedDescription
            }
        }
    }

    internal func apply() {
        guard session.runRefusalReason == nil, let target = session.target else { return }
        session.cancelRunningWork()
        session.errorMessage = nil

        let runProgress = Progress(totalUnitCount: Int64(session.statements.count))
        session.progress = runProgress
        let setupGeneration = session.setupGeneration
        let nonTransactionalObjects = session.mode == .data
            ? session.nonTransactionalTables(in: session.statements)
            : []

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
                        progress: runProgress,
                        nonTransactionalObjects: nonTransactionalObjects
                    )
                }
                /// Set from the result, not before the run. Setting it up front meant a declined
                /// authorization or a driver that could not run the script still flipped the status
                /// strip to "written", next to text that still read "Nothing has been written."
                session.hasWrittenToTarget = session.hasWrittenToTarget || result.writtenStatementCount > 0
                /// The setup cannot change while a run applies, and this is the fence if it did:
                /// the result describes the pair it ran against, so it is never published onto
                /// another.
                guard session.isCurrent(setupGeneration) else {
                    Self.announceCatalogChange(in: target)
                    return
                }
                session.runResult = result
                session.lastAction = .applied(
                    Date(), target: target.qualifiedDescription, statements: result.executedCount
                )
                /// The Apply sheet closes before the run starts, so the result it would have shown
                /// is reported on the window instead. A rollback that could not reach every table is
                /// the case this exists for.
                session.reportRunResult(result, target: target)
                /// The script just ran, so it describes work the target has already had. Leaving it
                /// armed left Apply enabled on a stale plan, one click from running the same
                /// CREATE/ALTER/DELETE a second time.
                session.markAppliedAndStale()
                Self.announceCatalogChange(in: target)
            } catch is CancellationError {
                Self.announceCatalogChange(in: target)
            } catch {
                session.errorMessage = error.localizedDescription
                Self.announceCatalogChange(in: target)
            }
        }
    }

    /// A sync script runs DDL against the target, and one that failed or was stopped part way may
    /// already have changed it, so every way out of a run reports the target's catalog as changed.
    private static func announceCatalogChange(in target: DatabaseEndpoint) {
        CatalogChangeService.post(
            .changed(
                CatalogChange(
                    connectionId: target.scope.connectionId,
                    database: target.scope.database,
                    kinds: .everything
                )
            )
        )
    }

    // MARK: - Context

    internal struct Context {
        internal let source: DatabaseEndpoint
        internal let target: DatabaseEndpoint
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

    private func missingConnection(_ endpoint: DatabaseEndpoint) -> String {
        String(
            format: String(localized: "%@ is no longer a saved connection."),
            endpoint.connectionName
        )
    }

    internal func capabilityRefusal(_ context: Context) async throws -> String? {
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

    internal struct StructureComparison {
        internal let report: CompareReport
        internal let sourceSnapshots: [String: TableStructureSnapshot]
        internal let targetSnapshots: [String: TableStructureSnapshot]
    }

    private func runStructureCompare(_ context: Context, claim: CompareSyncSession.RunClaim) async throws {
        let comparison = try await readAndCompareStructure(context)

        try Task.checkCancellation()
        guard session.ownsAnswer(claim) else { throw CancellationError() }

        /// Committed in one synchronous block. Writing the snapshots before the last await and the
        /// report after it let a reset in between leave one pair's snapshots under another pair's
        /// report, which a later script build then turned into DDL for the wrong target.
        session.sourceSnapshots = comparison.sourceSnapshots
        session.targetSnapshots = comparison.targetSnapshots
        session.report = comparison.report
        session.adoptActions(for: comparison.report)
        session.invalidateScript()
        session.selectedObjectId = session.visibleResults.first?.id
        session.lastAction = .compared(Date(), differences: comparison.report.differenceCount)
    }

    /// The comparison itself, with nothing published. The script build runs it a second time so the
    /// values it is about to generate from can be checked against the two databases as they stand,
    /// and running the comparison rather than a narrower re-read is what keeps the two answers in
    /// the same vocabulary: a verification that normalized differently would refuse honest scripts
    /// and pass dangerous ones.
    private func readAndCompareStructure(_ context: Context) async throws -> StructureComparison {
        let wantsViews = session.includedKinds.contains(.view)
            || session.includedKinds.contains(.materializedView)

        let (sourceReads, targetReads) = try await metadataService.bothSideTableReads(
            context: context, includeViews: wantsViews, profile: .structure
        )
        try Task.checkCancellation()

        let sourceTables = sourceReads.filter { CompareTableKindClassifier.kind(of: $0.table) == .table }
        let targetTables = targetReads.filter { CompareTableKindClassifier.kind(of: $0.table) == .table }

        let sourceSnapshots = sourceTables.compactMap {
            $0.snapshot?.droppingCatalogSpellings(ownSchema: context.source.schema)
        }
        let targetSnapshots = targetTables.compactMap {
            $0.snapshot?.droppingCatalogSpellings(ownSchema: context.target.schema)
        }

        let engine = StructureDiffEngine(options: session.structureOptions)
        let tableReport = engine.compare(source: sourceSnapshots, target: targetSnapshots)

        let sourceByName = Dictionary(
            sourceSnapshots.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let targetByName = Dictionary(
            targetSnapshots.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first }
        )

        var results = tableReport.results.map { result -> CompareObjectResult in
            CompareObjectResult.from(
                result,
                sourceDefinition: sourceByName[result.id].map(TableDefinitionRenderer.lines) ?? [],
                targetDefinition: targetByName[result.id].map(TableDefinitionRenderer.lines) ?? []
            )
        }
        results += unreadableResults(sourceTables, targetTables)
        results += try await sourceDefinedResults(context, sourceReads: sourceReads, targetReads: targetReads)

        return StructureComparison(
            report: CompareReport(results: results),
            sourceSnapshots: sourceByName,
            targetSnapshots: targetByName
        )
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

        /// Each pair reads two independent endpoints, so the two sides run together rather than the
        /// second waiting out the first.
        if session.includedKinds.contains(.view) || session.includedKinds.contains(.materializedView) {
            let sourceViews = sourceReads.map(\.table).filter { CompareTableKindClassifier.kind(of: $0) != .table }
            let targetViews = targetReads.map(\.table).filter { CompareTableKindClassifier.kind(of: $0) != .table }
            async let sourceDefinitions = metadataService.viewDefinitions(
                for: context.source, connection: context.sourceConnection, views: sourceViews
            )
            async let targetDefinitions = metadataService.viewDefinitions(
                for: context.target, connection: context.targetConnection, views: targetViews
            )
            results += try await SourceObjectDiffEngine(options: session.structureOptions)
                .compare(source: sourceDefinitions, target: targetDefinitions)
        }

        if session.includedKinds.contains(.procedure) || session.includedKinds.contains(.function) {
            async let sourceRoutines = metadataService.routineReads(
                for: context.source, connection: context.sourceConnection
            )
            async let targetRoutines = metadataService.routineReads(
                for: context.target, connection: context.targetConnection
            )
            results += try await SourceObjectDiffEngine(options: session.structureOptions)
                .compare(source: sourceRoutines, target: targetRoutines)
                .filter { session.includedKinds.contains($0.identity.kind) }
        }

        if session.includedKinds.contains(.trigger) {
            async let sourceTriggers = metadataService.triggerReads(
                for: context.source,
                connection: context.sourceConnection,
                tables: sourceReads.map(\.table.name)
            )
            async let targetTriggers = metadataService.triggerReads(
                for: context.target,
                connection: context.targetConnection,
                tables: targetReads.map(\.table.name)
            )
            results += try await SourceObjectDiffEngine(options: session.structureOptions)
                .compare(source: sourceTriggers, target: targetTriggers)
        }

        return results
    }

    private func structureStatements(_ context: Context) async throws -> [SyncStatement] {
        guard let report = session.report else { return [] }
        let snapshots = session.sourceSnapshots
        let selected = report.comparable.filter { session.action(for: $0) != .skip }
        try await refuseIfObjectsChanged(context, selected: selected, snapshots: snapshots)
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
            var statements = try SchemaSyncScriptBuilder(
                targetDriver: plugin, targetDatabaseType: driver.connection.type
            ).build(operations: tableOperations, foreignKeysByTable: foreignKeys)
            let sourceBuilder = SourceObjectSyncBuilder(
                targetDriver: plugin, targetDatabaseType: driver.connection.type
            )
            for entry in sourceDefined {
                statements += sourceBuilder.build(for: entry.result, action: entry.action)
            }
            return statements
        }
    }

    /// The DDL is written from what the comparison saw, and nothing looks at either database again
    /// before it runs. A window left open while someone else works on the target is enough to
    /// produce a CREATE TABLE without a column added since, or a DROP of a table that was recreated
    /// with rows in it, both reported as success.
    private func refuseIfObjectsChanged(
        _ context: Context,
        selected: [CompareObjectResult],
        snapshots: [String: TableStructureSnapshot]
    ) async throws {
        let expected = StructureChangeGuard.inputs(
            for: selected, actions: { session.action(for: $0) }, sourceSnapshots: snapshots
        )
        guard !expected.isEmpty else { return }

        let verification = try await readAndCompareStructure(context)
        let actions = Dictionary(
            selected.map { ($0.id, session.action(for: $0)) }, uniquingKeysWith: { first, _ in first }
        )
        let actual = StructureChangeGuard.inputs(
            for: verification.report.comparable,
            actions: { actions[$0.id] ?? .skip },
            sourceSnapshots: verification.sourceSnapshots
        )
        if let refusal = StructureChangeGuard.refusal(expected: expected, actual: actual) {
            throw refusal
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
