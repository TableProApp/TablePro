//
//  CompareRunner+Data.swift
//  TablePro
//
//  The data half: building the per-table plans, running the merge join for each,
//  and turning the result into DML.
//
//  Statements are ordered across tables, not just within one. A flat
//  inserts-then-updates-then-deletes per table, emitted in alphabetical order,
//  puts a child row's INSERT before its parent's and the server refuses it. So
//  every table's inserts run parent-first, then the updates, then the deletes
//  child-first, which is the only ordering that satisfies a foreign key in both
//  directions.
//

import Foundation
import TableProPluginKit

internal extension CompareRunner {
    /// Lists the tables the two sides share, without reading a row.
    ///
    /// The guard is `hasLoadedDataPlans` rather than an empty list, because two sides that share no
    /// table produce an empty list from a load that did happen, and a caller on a validation pass
    /// would reload it forever.
    func loadDataPlans() {
        guard session.mode == .data, session.canCompare, !session.hasLoadedDataPlans else { return }
        session.errorMessage = nil

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
                let read = try await buildPlans(context)
                guard session.ownsAnswer(claim) else { return }
                adopt(read)
            } catch is CancellationError {
            } catch {
                guard session.ownsAnswer(claim) else { return }
                session.errorMessage = error.localizedDescription
            }
        }
    }

    func runDataCompare(_ context: Context, claim: CompareSyncSession.RunClaim) async throws {
        if let refusal = rowService.concurrentReadRefusal(source: context.source, target: context.target) {
            throw CompareSyncError.unsupportedOperation(refusal)
        }

        /// The metadata is read again on every explicit Compare, never reused from the preload.
        /// A table's key can have been dropped since, and a stale key still merges the two row
        /// streams and still addresses the UPDATE and DELETE it generates.
        let read = try await buildPlans(context)
        guard session.ownsAnswer(claim) else { throw CancellationError() }
        adopt(read)

        var compared: [DataComparePlan] = []
        for plan in session.dataPlans where plan.isEnabled && plan.isComparable {
            try Task.checkCancellation()
            var result = plan
            do {
                result.summary = try await rowService.compare(
                    plan: plan,
                    source: context.source,
                    sourceConnection: context.sourceConnection,
                    target: context.target,
                    targetConnection: context.targetConnection,
                    options: session.dataOptions
                )
                result.comparisonFailure = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.summary = nil
                result.comparisonFailure = error.localizedDescription
            }
            compared.append(result)
        }

        try Task.checkCancellation()
        guard session.ownsAnswer(claim) else { throw CancellationError() }
        session.applyComparedSummaries(from: compared)
        session.hasLoadedDataPlans = true
        session.isStaleAfterApply = false
        session.detailPane = .rows
        session.invalidateScript()

        let comparedAny = compared.contains { $0.summary != nil }
        guard comparedAny else {
            session.lastAction = .none
            session.informationalMessage = compared.isEmpty
                ? String(localized: "Nothing was compared. Tick the tables to compare, then press Compare.")
                : nil
            return
        }
        session.lastAction = .compared(Date(), differences: session.dataDifferenceTotal)
    }

    func dataStatements(_ context: Context) async throws -> [SyncStatement] {
        var byTable: [(plan: DataComparePlan, statements: DataSyncStatements)] = []

        for plan in session.dataPlans where plan.isEnabled && plan.isComparable {
            guard let summary = plan.summary,
                  plan.scriptableRowCount(options: session.dataOptions) > 0 else { continue }
            try Task.checkCancellation()
            let statements = try await rowService.buildStatements(
                plan: plan,
                source: context.source,
                sourceConnection: context.sourceConnection,
                target: context.target,
                targetConnection: context.targetConnection,
                options: session.dataOptions,
                expectedDigest: summary.differenceDigest
            )
            guard !statements.isEmpty else { continue }
            byTable.append((plan, statements))
        }
        guard !byTable.isEmpty else { return [] }

        let foreignKeys = CompareRunner.foreignKeyMap(from: session.sourceSnapshots)
        let nodes = byTable.map { ForeignKeyTopologicalSort.Table(name: $0.plan.table, schema: $0.plan.schema) }
        let parentFirst = ForeignKeyTopologicalSort
            .ordered(nodes, foreignKeysByTable: foreignKeys, childrenFirst: false)
            .map { $0.identifier }
        let ordered = Dictionary(byTable.map { ($0.plan.id, $0.statements) }, uniquingKeysWith: { first, _ in first })

        var result: [SyncStatement] = []
        for name in parentFirst {
            result += ordered[name]?.inserts ?? []
        }
        for name in parentFirst {
            result += ordered[name]?.updates ?? []
        }
        for name in parentFirst.reversed() {
            result += ordered[name]?.deletes ?? []
        }
        return result
    }

    // MARK: - Plans

    /// Everything one read of the two sides produced, so the caller publishes all of it behind one
    /// ownership check.
    struct DataPlanRead {
        let plans: [DataComparePlan]
        let sourceSnapshots: [String: TableStructureSnapshot]
        let unreadableTableCount: Int
    }

    private func adopt(_ read: DataPlanRead) {
        session.sourceSnapshots = read.sourceSnapshots
        session.unreadableTableCount = read.unreadableTableCount
        session.adoptDataPlans(read.plans)
    }

    private func buildPlans(_ context: Context) async throws -> DataPlanRead {
        let (sourceReads, targetReads) = try await metadataService.bothSideTableReads(
            context: context,
            includeViews: false,
            profile: .data,
            targetProfile: DataSyncTransactionality.needsStorageEngines(context.target.databaseType)
                ? .dataWithStorageEngines
                : .data
        )
        try Task.checkCancellation()

        let options = session.structureOptions
        let targetByKey = Dictionary(
            targetReads.map { (options.matchKey(name: $0.table.name, schema: $0.table.schema), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previous = Dictionary(
            session.dataPlans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let sourceSnapshots = Dictionary(
            sourceReads.compactMap { $0.sourceSnapshot }.map { ($0.qualifiedName, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var plans: [DataComparePlan] = []
        for read in sourceReads {
            guard read.failure == nil else { continue }
            let pairKey = options.matchKey(name: read.table.name, schema: read.table.schema)
            guard let counterpart = targetByKey[pairKey], counterpart.failure == nil else { continue }
            let plan = makePlan(
                read: read,
                counterpart: counterpart,
                context: context,
                previous: previous
            )
            plans.append(plan)
        }
        return DataPlanRead(
            plans: plans.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
            sourceSnapshots: sourceSnapshots,
            unreadableTableCount: (sourceReads + targetReads).filter { $0.failure != nil }.count
        )
    }

    private func makePlan(
        read: TableStructureRead,
        counterpart: TableStructureRead,
        context: Context,
        previous: [String: DataComparePlan]
    ) -> DataComparePlan {
        let targetColumns = Dictionary(
            counterpart.columns.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first }
        )
        let shared = read.columns.compactMap { column -> CompareColumn? in
            guard let targetColumn = targetColumns[column.name.lowercased()] else { return nil }
            return CompareColumn(
                name: column.name,
                sourceType: column.typeNameForClassification,
                targetType: targetColumn.typeNameForClassification,
                collation: column.collation,
                isGeneratedOnTarget: targetColumn.isGenerated,
                targetIdentity: targetColumn.identityKind
            )
        }
        let primaryKey = read.columns
            .filter { $0.isPrimaryKey && targetColumns[$0.name.lowercased()] != nil }
            .map(\.name)
        let schema = read.table.schema ?? context.source.schema
        let identifier = schema.map { "\($0).\(read.table.name)" } ?? read.table.name
        let carried = previous[identifier]

        var plan = DataComparePlan(
            table: read.table.name,
            schema: schema,
            targetSchema: counterpart.table.schema ?? context.target.schema,
            columns: shared,
            scope: carried?.scope ?? DataTableScope(keyColumns: primaryKey),
            isEnabled: carried?.isEnabled ?? false,
            targetStorageEngine: counterpart.metadata?.engine
        )
        plan.unavailableReason = DataComparePlan.unavailableReason(for: plan)
        guard let carried else { return plan }
        if carried.columns == plan.columns {
            plan.summary = carried.summary
            plan.comparisonFailure = carried.comparisonFailure
            plan.excludedRowKeys = carried.excludedRowKeys
        }
        return plan
    }
}
