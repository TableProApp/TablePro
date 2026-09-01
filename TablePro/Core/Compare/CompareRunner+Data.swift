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
    /// Data mode used to spend its first Compare on this list, because plans arrive unticked and a
    /// comparison of nothing reads nothing, so a data sync cost two Compares and paid the whole
    /// metadata read twice.
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
                    guard session.owns(claim) else { return }
                    session.errorMessage = refusal
                    return
                }
                let plans = try await buildPlans(context)
                /// The pair may have moved while this was reading. Publishing now would put one
                /// pair's tables, columns and snapshots behind another pair's Compare.
                guard session.owns(claim) else { return }
                session.adoptDataPlans(plans)
            } catch is CancellationError {
            } catch {
                guard session.owns(claim) else { return }
                session.errorMessage = error.localizedDescription
            }
        }
    }

    func runDataCompare(_ context: Context, claim: CompareSyncSession.RunClaim) async throws {
        if let refusal = rowService.concurrentReadRefusal(source: context.source, target: context.target) {
            throw CompareSyncError.unsupportedOperation(refusal)
        }

        /// The metadata is read again on every explicit Compare, never reused from the preload.
        /// The list on screen can be minutes old, and a table's key can have been dropped since:
        /// a stale key still merges the two row streams and still addresses the UPDATE and DELETE
        /// it generates, so one reviewed row's statement can reach every row sharing that value.
        /// `buildPlans` carries the user's ticks, keys and row exclusions onto the fresh list.
        let built = try await buildPlans(context)
        guard session.owns(claim) else { throw CancellationError() }
        session.adoptDataPlans(built)
        var plans = session.dataPlans

        for index in plans.indices where plans[index].isEnabled && plans[index].isComparable {
            try Task.checkCancellation()
            do {
                plans[index].summary = try await rowService.compare(
                    plan: plans[index],
                    source: context.source,
                    sourceConnection: context.sourceConnection,
                    target: context.target,
                    targetConnection: context.targetConnection,
                    options: session.dataOptions
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                plans[index].unavailableReason = error.localizedDescription
            }
        }

        try Task.checkCancellation()
        guard session.owns(claim) else { throw CancellationError() }
        session.dataPlans = plans
        session.hasLoadedDataPlans = true
        session.selectedPlanId = plans.first { $0.isEnabled && $0.isComparable }?.id ?? plans.first?.id
        session.detailPane = .rows
        session.invalidateScript()

        /// Plans start unchecked so a Compare cannot stream every row of every table by accident,
        /// which means a run with nothing ticked legitimately reads nothing. Recording that as
        /// "0 differences" invited the reader to conclude the two databases matched.
        let comparedAny = plans.contains { $0.isEnabled && $0.isComparable && $0.summary != nil }
        guard comparedAny else {
            session.lastAction = .none
            session.informationalMessage = String(
                localized: "Nothing was compared. Tick the tables to compare, then press Compare."
            )
            return
        }
        session.lastAction = .compared(Date(), differences: session.dataDifferenceTotal)
    }

    func dataStatements(_ context: Context) async throws -> [SyncStatement] {
        var byTable: [(plan: DataComparePlan, statements: DataSyncStatements)] = []

        for plan in session.dataPlans where plan.isEnabled && plan.isComparable {
            try Task.checkCancellation()
            let statements = try await rowService.buildStatements(
                plan: plan,
                source: context.source,
                sourceConnection: context.sourceConnection,
                target: context.target,
                targetConnection: context.targetConnection,
                options: session.dataOptions,
                excludedKeys: plan.excludedRowKeys
            )
            guard !statements.isEmpty else { continue }
            byTable.append((plan, statements))
        }
        guard !byTable.isEmpty else { return [] }

        /// `session.sourceSnapshots` is filled by the structure path only, so reading it here left
        /// the graph empty and the ordering fell back to alphabetical: `order_items` before
        /// `orders`, which is exactly the foreign key failure this ordering exists to prevent.
        /// The data path records its own snapshots when it builds the plans.
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

    private func buildPlans(_ context: Context) async throws -> [DataComparePlan] {
        let (sourceReads, targetReads) = try await metadataService.bothSideTableReads(
            context: context, includeViews: false, profile: .data
        )
        try Task.checkCancellation()
        session.unreadableTableCount = (sourceReads + targetReads).filter { $0.failure != nil }.count

        /// Keyed on schema and name, not name alone: two schemas of one database can hold the same
        /// table, and pairing on the bare name took the shared column set from the wrong
        /// counterpart while reading rows from the right one.
        let options = session.structureOptions
        let targetByKey = Dictionary(
            targetReads.map { (options.matchKey(name: $0.table.name, schema: $0.table.schema), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let previous = Dictionary(
            session.dataPlans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )

        session.sourceSnapshots = Dictionary(
            sourceReads.compactMap { $0.snapshot }.map { ($0.qualifiedName, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var plans: [DataComparePlan] = []
        for read in sourceReads {
            guard read.failure == nil else { continue }
            let pairKey = options.matchKey(name: read.table.name, schema: read.table.schema)
            guard let counterpart = targetByKey[pairKey], counterpart.failure == nil else { continue }
            let targetNames = Set(counterpart.columns.map { $0.name.lowercased() })
            let shared = read.columns.filter { targetNames.contains($0.name.lowercased()) }
            let schema = read.table.schema ?? context.source.schema
            let identifier = schema.map { "\($0).\(read.table.name)" } ?? read.table.name
            let carried = previous[identifier]

            var plan = DataComparePlan(
                table: read.table.name,
                schema: schema,
                targetSchema: counterpart.table.schema ?? context.target.schema,
                columns: shared.map { $0.name },
                columnDescriptors: shared.map {
                    KeyColumnDescriptor(name: $0.name, dataType: $0.dataType, collation: $0.collation)
                },
                generatedColumns: Set(shared.filter { $0.isGenerated }.map { $0.name.lowercased() }),
                keyColumns: carried?.keyColumns ?? shared.filter { $0.isPrimaryKey }.map { $0.name },
                isEnabled: carried?.isEnabled ?? false,
                excludedRowKeys: carried?.excludedRowKeys ?? []
            )
            plan.unavailableReason = DataComparePlan.unavailableReason(for: plan)
            plans.append(plan)
        }
        return plans.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
}
