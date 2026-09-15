//
//  DataComparePlan.swift
//  TablePro
//
//  One table's data comparison: the columns both sides share, the scope that
//  decides which rows take part and how they are matched, and the answer.
//
//  The column sets are deliberately different. A column generated on the target
//  is read and compared but never written, because the engine rejects an
//  explicit value for it. An excluded column is written but not compared, which
//  is what lets an `updated_at` be carried across without every row reading as
//  different.
//

import Foundation
import TableProPluginKit

internal struct CompareColumn: Hashable, Sendable {
    internal let name: String
    internal let sourceType: String?
    internal let targetType: String?
    internal let collation: String?
    internal let isGeneratedOnTarget: Bool
    internal let targetIdentity: IdentityKind?

    internal init(
        name: String,
        sourceType: String? = nil,
        targetType: String? = nil,
        collation: String? = nil,
        isGeneratedOnTarget: Bool = false,
        targetIdentity: IdentityKind? = nil
    ) {
        self.name = name
        self.sourceType = sourceType
        self.targetType = targetType
        self.collation = collation
        self.isGeneratedOnTarget = isGeneratedOnTarget
        self.targetIdentity = targetIdentity
    }

    internal var sourceColumnType: ColumnType? {
        sourceType.map { ColumnTypeClassifier().classify(rawTypeName: $0) }
    }

    internal var targetColumnType: ColumnType? {
        (targetType ?? sourceType).map { ColumnTypeClassifier().classify(rawTypeName: $0) }
    }
}

internal struct DataComparePlan: Identifiable, Hashable, Sendable {
    internal let table: String
    internal let schema: String?
    internal let targetSchema: String?
    internal var columns: [CompareColumn]
    internal var scope: DataTableScope
    internal var isEnabled: Bool
    internal var unavailableReason: String?
    internal var comparisonFailure: String?
    internal var summary: DataDiffSummary?
    internal var excludedRowKeys: Set<String>
    internal var targetStorageEngine: String?

    internal init(
        table: String,
        schema: String?,
        targetSchema: String? = nil,
        columns: [CompareColumn],
        scope: DataTableScope,
        isEnabled: Bool,
        unavailableReason: String? = nil,
        summary: DataDiffSummary? = nil,
        excludedRowKeys: Set<String> = [],
        targetStorageEngine: String? = nil
    ) {
        self.table = table
        self.schema = schema
        self.targetSchema = targetSchema ?? schema
        self.columns = columns
        self.scope = scope
        self.isEnabled = isEnabled
        self.unavailableReason = unavailableReason
        self.summary = summary
        self.excludedRowKeys = excludedRowKeys
        self.targetStorageEngine = targetStorageEngine
    }

    internal var id: String {
        guard let schema, !schema.isEmpty else { return table }
        return "\(schema).\(table)"
    }

    internal var isComparable: Bool {
        unavailableReason == nil
    }

    internal var columnNames: [String] {
        columns.map(\.name)
    }

    internal var keyColumns: [String] {
        scope.keyColumns
    }

    internal var comparedColumns: [String] {
        columnNames.filter { !scope.isKeyColumn($0) && !scope.isExcluded($0) }
    }

    internal var writeColumns: [String] {
        columns.filter { !$0.isGeneratedOnTarget }.map(\.name)
    }

    internal var updatableColumns: [String] {
        columns.filter { !$0.isGeneratedOnTarget && $0.targetIdentity != .always }.map(\.name)
    }

    internal var insertsIntoIdentityColumn: Bool {
        columns.contains { !$0.isGeneratedOnTarget && $0.targetIdentity == .always }
    }

    internal var keyDescriptors: [KeyColumnDescriptor] {
        keyColumns.compactMap { key in
            column(named: key).map {
                KeyColumnDescriptor(name: $0.name, dataType: $0.sourceType, collation: $0.collation)
            }
        }
    }

    internal func column(named name: String) -> CompareColumn? {
        columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    internal func isKeyColumn(_ column: String) -> Bool {
        scope.isKeyColumn(column)
    }

    internal func isGeneratedColumn(_ column: String) -> Bool {
        self.column(named: column)?.isGeneratedOnTarget ?? false
    }

    internal var comparisonShape: DataComparisonShape {
        DataComparisonShape(
            keyColumns: keyColumns,
            keyOrders: KeyOrdering.orders(for: keyColumns, descriptors: keyDescriptors),
            comparedColumns: comparedColumns,
            valueKinds: Dictionary(
                columns.map {
                    ($0.name.lowercased(), ValueComparisonKind(columnType: $0.sourceColumnType ?? $0.targetColumnType))
                },
                uniquingKeysWith: { first, _ in first }
            ),
            digestColumns: columnNames,
            defersOneSidedRows: scope.hasFilter
        )
    }

    internal func scriptableRowCount(options: DataCompareOptions) -> Int {
        guard let summary else { return 0 }
        var excluded: [RowDiffKind: Int] = [:]
        for entry in summary.entries where excludedRowKeys.contains(entry.keyIdentity) {
            excluded[entry.kind, default: 0] += 1
        }
        var total = 0
        for kind in [RowDiffKind.insert, .update, .delete] where options.writesRows(of: kind) {
            total += max(0, summary.count(of: kind) - (excluded[kind] ?? 0))
        }
        return total
    }

    internal static func == (lhs: DataComparePlan, rhs: DataComparePlan) -> Bool {
        lhs.id == rhs.id
            && lhs.columns == rhs.columns
            && lhs.scope == rhs.scope
            && lhs.isEnabled == rhs.isEnabled
            && lhs.unavailableReason == rhs.unavailableReason
            && lhs.comparisonFailure == rhs.comparisonFailure
            && lhs.excludedRowKeys == rhs.excludedRowKeys
            && lhs.summary?.answerIdentity == rhs.summary?.answerIdentity
    }

    internal func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

internal extension DataComparePlan {
    static func unavailableReason(for plan: DataComparePlan) -> String? {
        if plan.columns.isEmpty {
            return String(localized: "No columns in common.")
        }
        if plan.keyColumns.isEmpty {
            return String(localized: "No primary key. Choose key columns to compare this table.")
        }
        let missing = plan.keyColumns.filter { plan.column(named: $0) == nil }
        guard missing.isEmpty else {
            return String(
                format: String(localized: "Key column %@ is not present on both sides. Choose a different key."),
                missing.joined(separator: ", ")
            )
        }
        if plan.writeColumns.isEmpty {
            return String(localized: "Every shared column is generated, so there is nothing to write.")
        }
        return plan.scope.filterValidationError
    }
}
