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
        /// Two scopes that are the same scope reach one pooled entry, and that entry runs its work
        /// serially: the inner scope waits on a tail that only the outer scope can finish, so the
        /// comparison hangs with no error and the entry is wedged for everything else. The window's
        /// own button already refuses this pair, but a hang with nothing to report is worth
        /// refusing where the scopes are opened rather than only where they are chosen.
        guard source.scope != target.scope else {
            return String(localized: "The source and the target are the same database.")
        }
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
        ) { engine, sides in
            try await engine.compare(source: sides.source, target: sides.target, resolver: sides.resolver)
        }
    }

    /// Runs the walk a second time, building statements as entries arrive rather than reading the
    /// review pane's capped entry list. The walk's difference digest has to match the one the
    /// comparison produced, so a script can only carry rows someone could have reviewed.
    internal func buildStatements(
        plan: DataComparePlan,
        source: DatabaseEndpoint,
        sourceConnection: DatabaseConnection,
        target: DatabaseEndpoint,
        targetConnection: DatabaseConnection,
        options: DataCompareOptions,
        expectedDigest: String
    ) async throws -> DataSyncStatements {
        let targetType = target.databaseType
        let excludedKeys = plan.excludedRowKeys
        let tableName = plan.id

        return try await withBothSides(
            source: source, sourceConnection: sourceConnection,
            target: target, targetConnection: targetConnection,
            plan: plan, options: options
        ) { engine, sides in
            let collector = SyncStatementCollector(
                builder: DataSyncScriptBuilder(
                    targetDriver: sides.targetDriver, targetDatabaseType: targetType, options: options, plan: plan
                )
            )
            let summary = try await engine.compare(
                source: sides.source, target: sides.target, resolver: sides.resolver
            ) { entry in
                guard !excludedKeys.contains(entry.keyIdentity) else { return }
                collector.append(entry)
            }
            guard summary.differenceDigest == expectedDigest else {
                throw CompareSyncError.rowsChangedSinceComparison(
                    String(
                        format: String(
                            localized: "Rows in %@ changed after they were compared. Compare again before generating the script."
                        ),
                        tableName
                    )
                )
            }
            return collector.finished()
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
        _ body: @escaping @Sendable (DataDiffEngine, RowSides) async throws -> T
    ) async throws -> T {
        if let refusal = concurrentReadRefusal(source: source, target: target) {
            throw CompareSyncError.unsupportedOperation(refusal)
        }
        if let invalidFilter = plan.scope.filterValidationError {
            throw CompareSyncError.invalidFilter(invalidFilter)
        }
        try await manager.ensureConnected(sourceConnection)
        try await manager.ensureConnected(targetConnection)

        let engine = DataDiffEngine(options: options, shape: plan.comparisonShape)
        let sourceRead = SideRead(
            endpoint: source,
            table: plan.table,
            schema: source.schema ?? plan.schema,
            columns: plan.columnNames,
            keyColumns: plan.keyColumns,
            keyTypes: plan.keyColumns.map { plan.column(named: $0)?.sourceColumnType },
            filter: plan.scope.effectiveSourceFilter,
            rowLimit: plan.scope.rowLimit,
            dialect: PluginManager.shared.sqlDialect(for: source.databaseType),
            side: .source
        )
        let targetRead = SideRead(
            endpoint: target,
            table: plan.table,
            schema: plan.targetSchema,
            columns: plan.columnNames,
            keyColumns: plan.keyColumns,
            keyTypes: plan.keyColumns.map { plan.column(named: $0)?.targetColumnType },
            filter: plan.scope.effectiveTargetFilter,
            rowLimit: plan.scope.rowLimit,
            dialect: PluginManager.shared.sqlDialect(for: target.databaseType),
            side: .target
        )

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
                let sides = RowSides(
                    source: sourceRead.provider(driver: sourcePlugin),
                    target: targetRead.provider(driver: targetPlugin),
                    resolver: KeyLookupResolver(
                        source: (sourceRead, sourcePlugin),
                        target: (targetRead, targetPlugin)
                    ),
                    targetDriver: targetPlugin
                )
                return try await body(engine, sides)
            }
        }
    }
}

private struct SideRead: Sendable {
    let endpoint: DatabaseEndpoint
    let table: String
    let schema: String?
    let columns: [String]
    let keyColumns: [String]
    let keyTypes: [ColumnType?]
    let filter: String?
    let rowLimit: Int?
    let dialect: SQLDialectDescriptor?
    let side: ComparisonSide

    func provider(driver: any PluginDatabaseDriver) -> StreamingRowProvider {
        let query = KeyOrderedQuery.build(
            table: table,
            schema: schema,
            columns: columns,
            keyColumns: keyColumns,
            filter: filter,
            rowLimit: rowLimit,
            driver: driver,
            databaseType: endpoint.databaseType,
            dialect: dialect
        )
        return StreamingRowProvider(
            stream: driver.streamRows(query: query),
            columns: columns,
            rowLimit: rowLimit,
            context: RowReadContext(side: side, isFiltered: filter != nil)
        )
    }

    func lookupProvider(keys: [[PluginCellValue]], driver: any PluginDatabaseDriver) -> StreamingRowProvider {
        let query = KeyOrderedQuery.lookup(
            table: table,
            schema: schema,
            columns: columns,
            keyColumns: keyColumns,
            keyTypes: keyTypes,
            keys: keys,
            driver: driver,
            databaseType: endpoint.databaseType
        )
        return StreamingRowProvider(
            stream: driver.streamRows(query: query),
            columns: columns,
            context: RowReadContext(side: side, isFiltered: false)
        )
    }
}

private struct RowSides {
    let source: StreamingRowProvider
    let target: StreamingRowProvider
    let resolver: KeyLookupResolver
    let targetDriver: any PluginDatabaseDriver
}

private final class KeyLookupResolver: OneSidedRowResolving {
    private let source: (read: SideRead, driver: any PluginDatabaseDriver)
    private let target: (read: SideRead, driver: any PluginDatabaseDriver)

    init(
        source: (read: SideRead, driver: any PluginDatabaseDriver),
        target: (read: SideRead, driver: any PluginDatabaseDriver)
    ) {
        self.source = source
        self.target = target
    }

    func rows(matching keys: [[PluginCellValue]], on side: ComparisonSide) async throws -> [DataRow] {
        guard !keys.isEmpty else { return [] }
        let chosen = side == .source ? source : target
        let provider = chosen.read.lookupProvider(keys: keys, driver: chosen.driver)
        var rows: [DataRow] = []
        while let row = try await provider.nextRow() {
            rows.append(row)
        }
        return rows
    }
}

/// The merge join hands entries out one at a time from inside a `@Sendable` closure, so the
/// accumulation cannot be a captured `var`. A reference box keeps it simple without reaching for
/// an actor the single-threaded walk does not need.
private final class SyncStatementCollector: @unchecked Sendable {
    private let builder: DataSyncScriptBuilder
    private var statements = DataSyncStatements()

    init(builder: DataSyncScriptBuilder) {
        self.builder = builder
    }

    func append(_ entry: RowDiffEntry) {
        builder.append(entry, into: &statements)
    }

    func finished() -> DataSyncStatements {
        var result = statements
        builder.finish(&result)
        return result
    }
}
