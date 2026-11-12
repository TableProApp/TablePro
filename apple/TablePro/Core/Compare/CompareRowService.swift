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

internal enum ConcurrentReadRefusal: Equatable, Sendable {
    case sameScope
    case sharedConnection(DatabaseType)

    internal var comparisonMessage: String {
        switch self {
        case .sameScope:
            return String(localized: "The source and the target are the same database.")
        case .sharedConnection(let databaseType):
            return String(
                format: String(
                    localized: "%@ cannot compare two of its own databases at once, because it reads both through one connection. Use a second connection for the target."
                ),
                databaseType.rawValue
            )
        }
    }
}

@MainActor
internal struct CompareRowService {
    private let manager: DatabaseManager
    private let gate: any ExecutionGate

    internal init(manager: DatabaseManager = .shared, gate: any ExecutionGate = ExecutionGateProvider.shared) {
        self.manager = manager
        self.gate = gate
    }

    internal func concurrentReadRefusal(
        source: DatabaseEndpoint,
        target: DatabaseEndpoint
    ) -> ConcurrentReadRefusal? {
        guard source.connectionId == target.connectionId else { return nil }
        /// Two scopes that are the same scope reach one pooled entry, and that entry runs its work
        /// serially: the inner scope waits on a tail that only the outer scope can finish, so the
        /// comparison hangs with no error and the entry is wedged for everything else. The window's
        /// own button already refuses this pair, but a hang with nothing to report is worth
        /// refusing where the scopes are opened rather than only where they are chosen.
        guard source.scope != target.scope else { return .sameScope }
        let routes = [manager.metadataRoute(for: source.scope), manager.metadataRoute(for: target.scope)]
        guard routes.contains(where: { $0 != .pooled }) else { return nil }
        return .sharedConnection(source.databaseType)
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
            let immutableColumns = try await sides.targetDriver.fetchImmutableColumns(
                table: plan.table, schema: plan.targetSchema
            )
            let collector = SyncStatementCollector(
                builder: DataSyncScriptBuilder(
                    targetDriver: sides.targetDriver,
                    targetDatabaseType: targetType,
                    options: options,
                    plan: plan,
                    immutableColumns: immutableColumns
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

    // A filter is the user's own text, read on a connection that may be at Read-Only: it meets the gate as a Run would.
    private func authorizeReadOnlyFilter(
        _ filter: String?,
        on endpoint: DatabaseEndpoint,
        schema: String?,
        table: String
    ) async throws {
        let driver = manager.driver(for: endpoint.connectionId)
        let statement = ReadOnlyReadGate.filterStatement(
            table: table, schema: schema, filter: filter, databaseType: endpoint.databaseType
        ) { name in
            driver?.quoteIdentifier(name) ?? name
        }
        try await ReadOnlyReadGate.authorize(
            statement.map { [$0] } ?? [],
            connectionId: endpoint.connectionId,
            databaseType: endpoint.databaseType,
            gate: gate,
            operationDescription: String(localized: "Execute Query"),
            manager: manager
        )
    }

    // The sides are built inside the lift: a stream starts its statement when it is built, and a bounded one parks
    // its connection once its buffer is full, so a lift sent after it would wait behind that statement for good.
    internal static func readingBothSides<Sides, T>(
        liftingTimeoutOn drivers: [DatabaseDriver],
        sides makeSides: () -> Sides,
        _ body: (Sides) async throws -> T
    ) async throws -> T {
        try await BulkReadTimeout.lifted(on: drivers) {
            try await body(makeSides())
        }
    }

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
            throw CompareSyncError.unsupportedOperation(refusal.comparisonMessage)
        }
        if let invalidFilter = plan.scope.filterValidationError(source: source.databaseType, target: target.databaseType) {
            throw CompareSyncError.invalidFilter(invalidFilter)
        }
        try await manager.ensureConnected(sourceConnection)
        try await manager.ensureConnected(targetConnection)
        try await authorizeReadOnlyFilter(plan.scope.effectiveSourceFilter, on: source, schema: source.schema ?? plan.schema, table: plan.table)
        try await authorizeReadOnlyFilter(plan.scope.effectiveTargetFilter, on: target, schema: plan.targetSchema, table: plan.table)
        let sourceIsReadOnly = ExecutionGateProvider.runsAtReadOnly(source.connectionId, in: manager)
        let targetIsReadOnly = ExecutionGateProvider.runsAtReadOnly(target.connectionId, in: manager)

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
            let sourceSide = sourceRead.carrying(sourceDriver.readOnlyRunContext(safeModeIsReadOnly: sourceIsReadOnly))
            return try await DatabaseManager.shared.withMetadataDriver(scope: target.scope) { targetDriver in
                guard let targetPlugin = CompareMetadataService.pluginDriver(from: targetDriver) else {
                    throw CompareSyncError.unsupportedOperation(
                        String(localized: "The target driver cannot stream rows for a comparison.")
                    )
                }
                let targetSide = targetRead.carrying(targetDriver.readOnlyRunContext(safeModeIsReadOnly: targetIsReadOnly))
                return try await Self.readingBothSides(liftingTimeoutOn: [sourceDriver, targetDriver]) {
                    RowSides(
                        source: sourceSide.provider(driver: sourcePlugin),
                        target: targetSide.provider(driver: targetPlugin),
                        resolver: KeyLookupResolver(
                            source: (sourceSide, sourcePlugin),
                            target: (targetSide, targetPlugin)
                        ),
                        targetDriver: targetPlugin
                    )
                } _: { sides in
                    try await body(engine, sides)
                }
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
    // Read-Only's, when the side's connection runs at it and its driver holds the engine to it.
    var context: PluginStatementContext?

    func carrying(_ context: PluginStatementContext?) -> SideRead {
        var read = self
        read.context = context
        return read
    }

    private func stream(_ query: String, driver: any PluginDatabaseDriver) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let context else { return driver.streamRows(query: query) }
        return driver.streamRows(query: query, context: context)
    }

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
            stream: stream(query, driver: driver),
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
            stream: stream(query, driver: driver),
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
