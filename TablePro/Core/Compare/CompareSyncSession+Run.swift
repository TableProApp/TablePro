//
//  CompareSyncSession+Run.swift
//  TablePro
//
//  Connecting, comparing, script generation, and applying.
//

import Foundation
import TableProPluginKit

internal extension CompareSyncSession {
    func compare() {
        guard canCompare, let source, let target else { return }
        cancelRunningWork()
        errorMessage = nil
        informationalMessage = nil

        runTask = Task { [weak self] in
            guard let self else { return }
            self.activity = .connecting
            defer { self.activity = .idle }

            do {
                let sourceDriver = try Self.driver(for: source)
                let targetDriver = try Self.driver(for: target)

                if let refusal = CompareSyncEligibility.refusalReason(
                    for: sourceDriver, mode: self.mode, endpointName: source.displayName
                ) ?? CompareSyncEligibility.refusalReason(
                    for: targetDriver, mode: self.mode, endpointName: target.displayName
                ) {
                    self.errorMessage = refusal
                    return
                }

                self.activity = .comparing
                let sourceSnapshots = try await Self.snapshots(from: sourceDriver, schema: source.schema)
                let targetSnapshots = try await Self.snapshots(from: targetDriver, schema: target.schema)
                try Task.checkCancellation()

                let engine = StructureDiffEngine(options: self.structureOptions)
                let report = engine.compare(source: sourceSnapshots, target: targetSnapshots)

                self.structureReport = report
                self.sourceSnapshotCache = Dictionary(
                    sourceSnapshots.map { ($0.qualifiedName, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.targetSnapshotCache = Dictionary(
                    targetSnapshots.map { ($0.qualifiedName, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                self.tableActions = [:]
                for result in report.comparable where self.pendingSelectedTables.contains(result.id) {
                    self.tableActions[result.id] = result.suggestedAction
                }
                self.pendingSelectedTables = []
                self.statements = []
                self.editedScript = nil
                self.lastAction = .compared(Date(), differences: report.comparable.filter { $0.status != .identical }.count)
                self.informationalMessage = self.crossEngineNotice
                self.step = .review
            } catch is CancellationError {
                self.informationalMessage = String(localized: "Comparison cancelled.")
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func generateScript() {
        guard let target, let report = structureReport else { return }
        guard canGenerateStructureScript else {
            errorMessage = crossEngineNotice
            return
        }
        errorMessage = nil

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let targetDriver = try Self.driver(for: target)
                let operations = self.operations(from: report)
                guard !operations.isEmpty else {
                    self.errorMessage = String(localized: "Nothing is selected to apply.")
                    return
                }
                let foreignKeys = Self.foreignKeyMap(from: self.sourceSnapshotCache)
                let builder = SchemaSyncScriptBuilder(targetDriver: targetDriver)
                self.statements = try builder.build(operations: operations, foreignKeysByTable: foreignKeys)
                self.editedScript = self.statements.map { $0.sql }.joined(separator: "\n")
                self.step = .script
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func apply() {
        guard let target, !statements.isEmpty else { return }
        cancelRunningWork()
        errorMessage = nil

        let runProgress = Progress(totalUnitCount: Int64(statements.count))
        progress = runProgress

        runTask = Task { [weak self] in
            guard let self else { return }
            self.activity = .applying
            self.hasWrittenToTarget = true
            CompareSyncRunRegistry.shared.markApplying(self, target: target.qualifiedDescription)
            defer {
                self.activity = .idle
                self.progress = nil
                CompareSyncRunRegistry.shared.clear(self)
            }

            do {
                let targetDriver = try Self.driver(for: target)
                let result = try await self.executorRun(
                    statements: self.statements,
                    target: target,
                    driver: targetDriver,
                    progress: runProgress
                )
                self.runResult = result
                self.lastAction = .applied(
                    Date(), target: target.qualifiedDescription, statements: result.executedCount
                )
                self.step = .apply
            } catch {
                self.errorMessage = error.localizedDescription
                self.step = .apply
            }
        }
    }

    // MARK: - Comparison

    private func operations(from report: StructureDiffReport) -> [SchemaSyncOperation] {
        report.comparable.compactMap { result in
            switch action(for: result) {
            case .skip:
                return nil
            case .create:
                guard let snapshot = sourceSnapshotCache[result.id] else { return nil }
                return .createTable(snapshot)
            case .drop:
                return .dropTable(name: result.tableName, schema: result.schema)
            case .alter:
                guard !result.changes.isEmpty else { return nil }
                return .alterTable(name: result.tableName, schema: result.schema, changes: result.changes)
            }
        }
    }

    private func executorRun(
        statements: [SyncStatement],
        target: CompareSyncEndpoint,
        driver: any PluginDatabaseDriver,
        progress: Progress
    ) async throws -> CompareSyncRunResult {
        try await CompareSyncExecutor().apply(
            statements: statements,
            mode: mode,
            settings: executionSettings,
            target: target,
            driver: driver,
            progress: progress
        )
    }

    // MARK: - Helpers

    private static func driver(for endpoint: CompareSyncEndpoint) throws -> any PluginDatabaseDriver {
        guard let adapter = DatabaseManager.shared.driver(for: endpoint.connectionId) as? PluginDriverAdapter else {
            throw CompareSyncError.unsupportedOperation(String(
                format: String(localized: "Connect to %@ before comparing."),
                endpoint.displayName
            ))
        }
        return adapter.schemaPluginDriver
    }

    private static func snapshots(
        from driver: any PluginDatabaseDriver,
        schema: String?
    ) async throws -> [TableStructureSnapshot] {
        let tables = try await driver.fetchTables(schema: schema)
        var result: [TableStructureSnapshot] = []
        for table in tables {
            try Task.checkCancellation()
            let columns = try await driver.fetchColumns(table: table.name, schema: table.schema ?? schema)
            let indexes = try await driver.fetchIndexes(table: table.name, schema: table.schema ?? schema)
            let foreignKeys = try await driver.fetchForeignKeys(table: table.name, schema: table.schema ?? schema)
            result.append(TableStructureSnapshot.from(
                table: table, columns: columns, indexes: indexes, foreignKeys: foreignKeys
            ))
        }
        return result
    }

    private static func foreignKeyMap(
        from snapshots: [String: TableStructureSnapshot]
    ) -> [String: [PluginForeignKeyInfo]] {
        var map: [String: [PluginForeignKeyInfo]] = [:]
        for snapshot in snapshots.values {
            let dependencies = snapshot.foreignKeys.compactMap { foreignKey -> PluginForeignKeyInfo? in
                guard let column = foreignKey.columns.first,
                      let referencedColumn = foreignKey.referencedColumns.first else { return nil }
                return PluginForeignKeyInfo(
                    name: foreignKey.name,
                    column: column,
                    referencedTable: foreignKey.referencedTable,
                    referencedColumn: referencedColumn,
                    referencedSchema: foreignKey.referencedSchema
                )
            }
            guard !dependencies.isEmpty else { continue }
            map[snapshot.name] = dependencies
        }
        return map
    }
}
