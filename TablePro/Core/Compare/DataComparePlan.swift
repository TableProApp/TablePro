//
//  DataComparePlan.swift
//  TablePro
//
//  One table's data comparison: which columns identify a row, which take part
//  in the comparison, and which get written.
//
//  Those three sets are deliberately different. A generated column is read and
//  compared but never written, because an engine rejects an explicit value for
//  one. An excluded column is written but not compared, which is what lets an
//  `updated_at` be carried across without every row reading as different.
//

import Foundation
import TableProPluginKit

internal struct DataComparePlan: Identifiable, Hashable, Sendable {
    internal let table: String
    internal let schema: String?

    /// The counterpart's schema, which is not always the source's. Reading the target with the
    /// source's schema name is how a comparison of `audit.users` read `public.users`' columns.
    internal let targetSchema: String?
    internal var columns: [String]
    internal var columnDescriptors: [KeyColumnDescriptor]
    internal var generatedColumns: Set<String>
    internal var keyColumns: [String]
    internal var isEnabled: Bool
    internal var unavailableReason: String?
    internal var summary: DataDiffSummary?
    internal var excludedRowKeys: Set<String>

    internal init(
        table: String,
        schema: String?,
        targetSchema: String? = nil,
        columns: [String],
        columnDescriptors: [KeyColumnDescriptor] = [],
        generatedColumns: Set<String> = [],
        keyColumns: [String],
        isEnabled: Bool,
        unavailableReason: String? = nil,
        summary: DataDiffSummary? = nil,
        excludedRowKeys: Set<String> = []
    ) {
        self.table = table
        self.schema = schema
        self.targetSchema = targetSchema ?? schema
        self.columns = columns
        self.columnDescriptors = columnDescriptors
        /// Normalised here rather than at the call site: every comparison is case-insensitive, and
        /// a caller that passed the engine's own spelling would silently write a generated column.
        self.generatedColumns = Set(generatedColumns.map { $0.lowercased() })
        self.keyColumns = keyColumns
        self.isEnabled = isEnabled
        self.unavailableReason = unavailableReason
        self.summary = summary
        self.excludedRowKeys = excludedRowKeys
    }

    internal var id: String {
        guard let schema, !schema.isEmpty else { return table }
        return "\(schema).\(table)"
    }

    internal var isComparable: Bool {
        unavailableReason == nil
    }

    /// Every shared column is read: a value is needed to compare it or to write it, and a second
    /// pass to fetch the rest would double the round trips.
    internal var readColumns: [String] {
        columns
    }

    /// A generated column is computed by the engine. MySQL rejects an explicit value for one
    /// outright, and PostgreSQL rejects it for a stored generated column, so it never appears in
    /// an INSERT or UPDATE column list.
    internal var writeColumns: [String] {
        columns.filter { !generatedColumns.contains($0.lowercased()) }
    }

    internal var comparisonColumnNames: [String] {
        columns
    }

    internal var keyDescriptors: [KeyColumnDescriptor] {
        let wanted = Set(keyColumns.map { $0.lowercased() })
        return columnDescriptors.filter { wanted.contains($0.name.lowercased()) }
    }

    internal func isKeyColumn(_ column: String) -> Bool {
        keyColumns.contains { $0.caseInsensitiveCompare(column) == .orderedSame }
    }

    internal func isGeneratedColumn(_ column: String) -> Bool {
        generatedColumns.contains(column.lowercased())
    }

    internal static func == (lhs: DataComparePlan, rhs: DataComparePlan) -> Bool {
        lhs.id == rhs.id
            && lhs.keyColumns == rhs.keyColumns
            && lhs.isEnabled == rhs.isEnabled
            && lhs.excludedRowKeys == rhs.excludedRowKeys
            && lhs.summary?.differenceCount == rhs.summary?.differenceCount
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
        let available = Set(plan.columns.map { $0.lowercased() })
        let missing = plan.keyColumns.filter { !available.contains($0.lowercased()) }
        guard missing.isEmpty else {
            return String(
                format: String(localized: "Key column %@ is not present on both sides. Choose a different key."),
                missing.joined(separator: ", ")
            )
        }
        if plan.writeColumns.isEmpty {
            return String(localized: "Every shared column is generated, so there is nothing to write.")
        }
        return nil
    }
}
