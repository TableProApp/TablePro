import Foundation

extension ImportMatchKey {
    static func options(columns: [ColumnInfo], indexes: [IndexInfo]) -> [ImportMatchKey] {
        options(
            columns: columns.map { ImportMatchKey.Column(name: $0.name, isPrimaryKey: $0.isPrimaryKey) },
            indexes: indexes.map { index in
                ImportMatchKey.Index(
                    name: index.name,
                    columns: index.columns,
                    isUnique: index.isUnique,
                    isPrimary: index.isPrimary,
                    isValid: index.isValid,
                    isPartial: index.whereClause != nil,
                    hasExpressions: !(index.expressions ?? []).isEmpty
                )
            }
        )
    }
}
