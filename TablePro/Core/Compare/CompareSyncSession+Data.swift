//
//  CompareSyncSession+Data.swift
//  TablePro
//
//  Data comparison. Rows are read in key order from both sides and walked in
//  lockstep. A table with no usable key is listed as not comparable rather than
//  matched on a guess.
//

import Foundation
import TableProPluginKit

internal struct DataComparePlan: Identifiable, Hashable {
    internal let table: String
    internal let schema: String?
    internal var columns: [String]
    internal var columnTypes: [String: String] = [:]
    internal var keyColumns: [String]
    internal var isEnabled: Bool
    internal var unavailableReason: String?
    internal var summary: DataDiffSummary?

    internal var id: String {
        guard let schema, !schema.isEmpty else { return table }
        return "\(schema).\(table)"
    }

    internal var isComparable: Bool {
        unavailableReason == nil
    }

    internal static func == (lhs: DataComparePlan, rhs: DataComparePlan) -> Bool {
        lhs.id == rhs.id && lhs.keyColumns == rhs.keyColumns && lhs.isEnabled == rhs.isEnabled
    }

    internal func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

internal extension CompareSyncSession {
    func compareData() {
        guard canCompare, let source, let target else { return }
        cancelRunningWork()
        errorMessage = nil
        informationalMessage = nil

        runTask = Task { [weak self] in
            guard let self else { return }
            self.activity = .connecting
            defer { self.activity = .idle }

            do {
                let sourceDriver = try Self.dataDriver(for: source)
                let targetDriver = try Self.dataDriver(for: target)

                if let refusal = CompareSyncEligibility.refusalReason(
                    for: sourceDriver, mode: .data, endpointName: source.displayName
                ) ?? CompareSyncEligibility.refusalReason(
                    for: targetDriver, mode: .data, endpointName: target.displayName
                ) {
                    self.errorMessage = refusal
                    return
                }

                self.activity = .comparing
                let pending = self.pendingSelectedTables
                var plans = try await Self.buildPlans(
                    sourceDriver: sourceDriver,
                    targetDriver: targetDriver,
                    sourceSchema: source.schema,
                    targetSchema: target.schema,
                    existing: self.dataPlans
                )

                if !pending.isEmpty {
                    for index in plans.indices {
                        plans[index].isEnabled = pending.contains(plans[index].id)
                    }
                    self.pendingSelectedTables = []
                }

                for index in plans.indices where plans[index].isEnabled && plans[index].isComparable {
                    try Task.checkCancellation()
                    plans[index].summary = try await self.runDataDiff(
                        plan: plans[index],
                        sourceDriver: sourceDriver,
                        targetDriver: targetDriver,
                        sourceSchema: source.schema,
                        targetSchema: target.schema
                    )
                }

                self.dataPlans = plans
                let differences = plans.compactMap { $0.summary?.differenceCount }.reduce(0, +)
                self.lastAction = .compared(Date(), differences: differences)
                self.informationalMessage = self.crossEngineNotice
                self.step = .review
            } catch is CancellationError {
                self.informationalMessage = String(localized: "Comparison cancelled.")
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func generateDataScript() {
        guard let target else { return }
        errorMessage = nil

        runTask = Task { [weak self] in
            guard let self else { return }
            do {
                let targetDriver = try Self.dataDriver(for: target)
                var built: [SyncStatement] = []
                for plan in self.dataPlans where plan.isEnabled && plan.isComparable {
                    guard let summary = plan.summary else { continue }
                    var options = self.dataOptions
                    options.keyColumns = plan.keyColumns
                    let builder = DataSyncScriptBuilder(targetDriver: targetDriver, options: options)
                    built.append(contentsOf: builder.build(
                        table: plan.table,
                        schema: plan.schema,
                        writeColumns: plan.columns,
                        entries: summary.entries
                    ))
                }
                guard !built.isEmpty else {
                    self.errorMessage = String(localized: "Nothing is selected to apply.")
                    return
                }
                self.statements = built
                self.editedScript = built.map { $0.sql }.joined(separator: "\n")
                self.step = .script
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    var dataDifferenceTotal: Int {
        dataPlans.compactMap { $0.summary?.differenceCount }.reduce(0, +)
    }

    var truncatedPlanNames: [String] {
        dataPlans.filter { $0.summary?.truncatedEntries == true }.map { $0.id }
    }

    // MARK: - Helpers

    private func runDataDiff(
        plan: DataComparePlan,
        sourceDriver: any PluginDatabaseDriver,
        targetDriver: any PluginDatabaseDriver,
        sourceSchema: String?,
        targetSchema: String?
    ) async throws -> DataDiffSummary {
        var options = dataOptions
        options.keyColumns = plan.keyColumns

        let sourceQuery = KeyOrderedQuery.build(
            table: plan.table, schema: sourceSchema, columns: plan.columns,
            keyColumns: plan.keyColumns, driver: sourceDriver
        )
        let targetQuery = KeyOrderedQuery.build(
            table: plan.table, schema: targetSchema, columns: plan.columns,
            keyColumns: plan.keyColumns, driver: targetDriver
        )

        let engine = DataDiffEngine(options: options, columns: plan.columns, columnTypes: plan.columnTypes)
        return try await engine.compare(
            source: StreamingRowProvider(stream: sourceDriver.streamRows(query: sourceQuery), columns: plan.columns),
            target: StreamingRowProvider(stream: targetDriver.streamRows(query: targetQuery), columns: plan.columns)
        )
    }

    private static func dataDriver(for endpoint: CompareSyncEndpoint) throws -> any PluginDatabaseDriver {
        guard let adapter = DatabaseManager.shared.driver(for: endpoint.connectionId) as? PluginDriverAdapter else {
            throw CompareSyncError.unsupportedOperation(String(
                format: String(localized: "Connect to %@ before comparing."),
                endpoint.displayName
            ))
        }
        return adapter.schemaPluginDriver
    }

    private static func buildPlans(
        sourceDriver: any PluginDatabaseDriver,
        targetDriver: any PluginDatabaseDriver,
        sourceSchema: String?,
        targetSchema: String?,
        existing: [DataComparePlan]
    ) async throws -> [DataComparePlan] {
        let sourceTables = try await sourceDriver.fetchTables(schema: sourceSchema)
        let targetNames = Set(try await targetDriver.fetchTables(schema: targetSchema).map { $0.name.lowercased() })
        let previous = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var plans: [DataComparePlan] = []
        for table in sourceTables where targetNames.contains(table.name.lowercased()) {
            try Task.checkCancellation()
            let sourceColumns = try await sourceDriver.fetchColumns(table: table.name, schema: table.schema ?? sourceSchema)
            let targetColumns = try await targetDriver.fetchColumns(table: table.name, schema: table.schema ?? targetSchema)
            let targetNameSet = Set(targetColumns.map { $0.name.lowercased() })
            let shared = sourceColumns.filter { targetNameSet.contains($0.name.lowercased()) }.map { $0.name }

            let primaryKey = sourceColumns.filter { $0.isPrimaryKey }.map { $0.name }
            let identifier = table.schema.map { "\($0).\(table.name)" } ?? table.name
            let carried = previous[identifier]
            let columnTypes = Dictionary(
                sourceColumns.map { ($0.name, $0.dataType) },
                uniquingKeysWith: { first, _ in first }
            )

            var plan = DataComparePlan(
                table: table.name,
                schema: table.schema ?? sourceSchema,
                columns: shared,
                columnTypes: columnTypes,
                keyColumns: carried.map { $0.keyColumns } ?? primaryKey,
                isEnabled: carried?.isEnabled ?? true,
                unavailableReason: nil,
                summary: nil
            )
            plan.unavailableReason = Self.unavailableReason(for: plan)
            plans.append(plan)
        }
        return plans.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    static func unavailableReason(for plan: DataComparePlan) -> String? {
        if plan.columns.isEmpty {
            return String(localized: "No columns in common.")
        }
        if plan.keyColumns.isEmpty {
            return String(localized: "No primary key. Choose key columns to compare this table.")
        }
        let available = Set(plan.columns.map { $0.lowercased() })
        let missing = plan.keyColumns.filter { !available.contains($0.lowercased()) }
        guard missing.isEmpty else {
            return String(
                format: String(localized: "Key column %@ is not present on both sides. Choose a different key."),
                missing.joined(separator: ", ")
            )
        }
        return nil
    }
}
