//
//  CompareRowService.swift
//  TablePro
//
//  Reads both sides' rows for a data comparison.
//
//  A merge join needs both streams open at once, so the two scoped-driver
//  closures nest. That is safe only when the two scopes reach two drivers.
//  `SessionDriverGate` is not reentrant, and a connection's shared driver holds
//  one database position, so two scopes that both route to the session driver
//  on the same connection cannot be open together: nesting them would block
//  forever, and even if it did not, pinning the driver to the second scope
//  would move the first out from under its own stream. `refusalReason` is that
//  check, made before anything opens.
//

import Foundation
import TableProPluginKit

@MainActor
internal struct CompareRowService {
    private let manager: DatabaseManager

    internal init(manager: DatabaseManager = .shared) {
        self.manager = manager
    }

    internal func concurrentReadRefusal(
        source: DatabaseEndpoint,
        target: DatabaseEndpoint
    ) -> String? {
        guard source.connectionId == target.connectionId else { return nil }
        let routes = [manager.metadataRoute(for: source.scope), manager.metadataRoute(for: target.scope)]
        guard routes.contains(where: { $0 != .pooled }) else { return nil }
        return String(
            format: String(
                localized: "%@ cannot compare two of its own databases at once, because it reads both through one connection. Use a second connection for the target."
            ),
            source.databaseType.rawValue
        )
    }

    internal func compare(
        plan: DataComparePlan,
        source: DatabaseEndpoint,
        sourceConnection: DatabaseConnection,
        target: DatabaseEndpoint,
        targetConnection: DatabaseConnection,
        options: DataCompareOptions
    ) async throws -> DataDiffSummary {
        try await withBothSides(
            source: source, sourceConnection: sourceConnection,
            target: target, targetConnection: targetConnection,
            plan: plan, options: options
        ) { engine, sourceProvider, targetProvider in
            try await engine.compare(source: sourceProvider, target: targetProvider)
        }
    }

    /// Runs the walk a second time, building statements as entries arrive rather than reading the
    /// review pane's capped entry list. Building from that list emitted 5,000 statements for a
    /// 12,000 row difference and reported the run as complete.
    internal func buildStatements(
        plan: DataComparePlan,
        source: DatabaseEndpoint,
        sourceConnection: DatabaseConnection,
        target: DatabaseEndpoint,
        targetConnection: DatabaseConnection,
        options: DataCompareOptions,
        excludedKeys: Set<String>
    ) async throws -> DataSyncStatements {
        let targetType = target.databaseType
        let table = plan.table
        let schema = plan.schema
        let writeColumns = plan.writeColumns

        return try await withBothSides(
            source: source, sourceConnection: sourceConnection,
            target: target, targetConnection: targetConnection,
            plan: plan, options: options
        ) { engine, sourceProvider, targetProvider, targetDriver in
            let builder = DataSyncScriptBuilder(
                targetDriver: targetDriver, targetDatabaseType: targetType, options: options
            )
            let collector = SyncStatementCollector()
            _ = try await engine.compare(source: sourceProvider, target: targetProvider) { entry in
                guard !excludedKeys.contains(entry.keyIdentity) else { return }
                collector.append(entry, table: table, schema: schema, writeColumns: writeColumns, builder: builder)
            }
            return collector.statements
        }
    }

    // MARK: - Plumbing

    private func withBothSides<T: Sendable>(
        source: DatabaseEndpoint,
        sourceConnection: DatabaseConnection,
        target: DatabaseEndpoint,
        targetConnection: DatabaseConnection,
        plan: DataComparePlan,
        options: DataCompareOptions,
        _ body: @escaping @Sendable (
            DataDiffEngine, StreamingRowProvider, StreamingRowProvider, any PluginDatabaseDriver
        ) async throws -> T
    ) async throws -> T {
        if let refusal = concurrentReadRefusal(source: source, target: target) {
            throw CompareSyncError.unsupportedOperation(refusal)
        }
        try await manager.ensureConnected(sourceConnection)
        try await manager.ensureConnected(targetConnection)

        var scopedOptions = options
        scopedOptions.keyColumns = plan.keyColumns
        let engine = DataDiffEngine(
            options: scopedOptions,
            columns: plan.comparisonColumnNames,
            keyDescriptors: plan.keyDescriptors
        )
        let sourceSchema = source.schema ?? plan.schema
        let targetSchema = plan.targetSchema
        let readColumns = plan.readColumns
        let keyColumns = plan.keyColumns
        let table = plan.table

        return try await manager.withMetadataDriver(scope: source.scope) { sourceDriver in
            guard let sourcePlugin = CompareMetadataService.pluginDriver(from: sourceDriver) else {
                throw CompareSyncError.unsupportedOperation(
                    String(localized: "The source driver cannot stream rows for a comparison.")
                )
            }
            return try await DatabaseManager.shared.withMetadataDriver(scope: target.scope) { targetDriver in
                guard let targetPlugin = CompareMetadataService.pluginDriver(from: targetDriver) else {
                    throw CompareSyncError.unsupportedOperation(
                        String(localized: "The target driver cannot stream rows for a comparison.")
                    )
                }
                let sourceQuery = KeyOrderedQuery.build(
                    table: table, schema: sourceSchema, columns: readColumns,
                    keyColumns: keyColumns, driver: sourcePlugin
                )
                let targetQuery = KeyOrderedQuery.build(
                    table: table, schema: targetSchema, columns: readColumns,
                    keyColumns: keyColumns, driver: targetPlugin
                )
                let sourceProvider = StreamingRowProvider(
                    stream: sourcePlugin.streamRows(query: sourceQuery), columns: readColumns
                )
                let targetProvider = StreamingRowProvider(
                    stream: targetPlugin.streamRows(query: targetQuery), columns: readColumns
                )
                return try await body(engine, sourceProvider, targetProvider, targetPlugin)
            }
        }
    }

    private func withBothSides<T: Sendable>(
        source: DatabaseEndpoint,
        sourceConnection: DatabaseConnection,
        target: DatabaseEndpoint,
        targetConnection: DatabaseConnection,
        plan: DataComparePlan,
        options: DataCompareOptions,
        _ body: @escaping @Sendable (DataDiffEngine, StreamingRowProvider, StreamingRowProvider) async throws -> T
    ) async throws -> T {
        try await withBothSides(
            source: source, sourceConnection: sourceConnection,
            target: target, targetConnection: targetConnection,
            plan: plan, options: options
        ) { engine, sourceProvider, targetProvider, _ in
            try await body(engine, sourceProvider, targetProvider)
        }
    }
}

/// The merge join hands entries out one at a time from inside a `@Sendable` closure, so the
/// accumulation cannot be a captured `var`. A reference box keeps it simple without reaching for
/// an actor the single-threaded walk does not need.
private final class SyncStatementCollector: @unchecked Sendable {
    private(set) var statements = DataSyncStatements()

    func append(
        _ entry: RowDiffEntry,
        table: String,
        schema: String?,
        writeColumns: [String],
        builder: DataSyncScriptBuilder
    ) {
        builder.append(entry, table: table, schema: schema, writeColumns: writeColumns, into: &statements)
    }
}
