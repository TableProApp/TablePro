//
//  RowGenerationEligibility.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum RowGenerationEligibility {
    // Rows go in as SQL INSERTs, and a referenced table is sampled with an ordered, limited SELECT.
    internal static func supportsGeneration(
        editorLanguage: EditorLanguage,
        dialect: SQLDialectDescriptor?,
        writesRows: Bool
    ) -> Bool {
        editorLanguage == .sql && dialect != nil && writesRows
    }

    @MainActor
    internal static func supportsGeneration(_ databaseType: DatabaseType) -> Bool {
        supportsGeneration(
            editorLanguage: PluginManager.shared.editorLanguage(for: databaseType),
            dialect: try? resolveSQLDialect(for: databaseType),
            writesRows: ImportDataSinkAdapter.canWriteRows(into: databaseType)
        )
    }

    internal static func appliesTo(_ type: TableInfo.TableType) -> Bool {
        type == .table || type == .partitionedTable
    }
}
