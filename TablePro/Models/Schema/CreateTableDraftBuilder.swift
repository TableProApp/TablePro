//
//  CreateTableDraftBuilder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What a Create Table draft comes to: the statement plan it will run, and every row that is not
/// ready to run.
struct CreateTablePlan {
    /// Never carries indexes. An index is always its own statement, see `CreateTableDraftBuilder`.
    let definition: PluginCreateTableDefinition?
    let indexes: [PluginIndexDefinition]
    let issues: [SchemaDraftIssue]

    var isReadyToCreate: Bool { definition != nil && issues.isEmpty }
}

/// Turns the Create Table editor's working rows into a statement plan.
///
/// This exists because the view used to do it inline, in three filters that each demanded a
/// non-empty `name` and then dropped whatever failed:
///
///     foreignKeys: workingForeignKeys.filter { !$0.name.isEmpty && !$0.columns.isEmpty && … }
///
/// A new foreign key row's name is always empty and nothing in the grid fills it, so every foreign
/// key the user entered was deleted on the way to the driver, with no message and an SQL Preview
/// that agreed. No dialect requires the name, three drivers discard it, and the filter left out the
/// predicate that does matter: an empty referenced column list renders `REFERENCES "t" ()`, which
/// SQLite, PostgreSQL and DuckDB all reject.
///
/// So the split is: this type answers whether a row is **complete**, the driver answers how to
/// **spell** it, and `ForeignKeyDialect` answers what the engine's grammar takes. Three row states,
/// and the middle one is the whole point:
///
/// - **blank**: nothing typed. Ignored, because the editor seeds a blank column and `+` seeds blank
///   rows, and neither is something the user asked to create.
/// - **incomplete**: begun and unusable. An issue the user is shown. Never a silent drop.
/// - **complete**: emitted.
@MainActor
enum CreateTableDraftBuilder {
    /// Indexes are never folded into the `CREATE TABLE` statement, on any engine.
    ///
    /// PostgreSQL and DuckDB used to append their `CREATE INDEX` statements to the same returned
    /// string, and that only ran because `PQexec` and `duckdb_query` take a whole batch. SQLite's
    /// driver prepares with `sqlite3_prepare_v2(db, sql, -1, &stmt, nil)` and steps once, so a
    /// second statement in the string is compiled by nobody: the index would vanish exactly the way
    /// the foreign keys did. Every index therefore goes through `generateAddIndexSQL` as its own
    /// statement, which is also what the existing-table path in `SchemaStatementGenerator` does.
    static func plan(
        tableName: String,
        options: CreateTableOptions,
        columns: [EditableColumnDefinition],
        indexes: [EditableIndexDefinition],
        foreignKeys: [EditableForeignKeyDefinition],
        dialect: ForeignKeyDialect,
        includesEngineOptions: Bool
    ) -> CreateTablePlan {
        var issues: [SchemaDraftIssue] = []

        let resolvedColumns = resolveColumns(columns, into: &issues)
        let columnNames = Set(resolvedColumns.map(\.name))
        let resolvedIndexes = resolveIndexes(indexes, columnNames: columnNames, into: &issues)
        let resolvedForeignKeys = resolveForeignKeys(
            foreignKeys, columnNames: columnNames, dialect: dialect, into: &issues
        )

        let trimmedName = tableName.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            issues.append(SchemaDraftIssue(
                tab: .columns, row: nil, message: String(localized: "The table needs a name.")
            ))
        }
        if resolvedColumns.isEmpty {
            issues.append(SchemaDraftIssue(
                tab: .columns, row: nil,
                message: String(localized: "The table needs at least one column with a name and a type.")
            ))
        }

        guard !trimmedName.isEmpty, !resolvedColumns.isEmpty else {
            return CreateTablePlan(definition: nil, indexes: [], issues: issues)
        }

        let primaryKeyColumns = resolvedColumns.filter(\.isPrimaryKey).map(\.name)
        let definition = PluginCreateTableDefinition(
            tableName: trimmedName,
            columns: resolvedColumns.map { $0.toPlugin() },
            indexes: [],
            foreignKeys: resolvedForeignKeys.map { $0.toPlugin() },
            primaryKeyColumns: primaryKeyColumns,
            engine: includesEngineOptions ? options.engine : nil,
            charset: includesEngineOptions ? options.charset : nil,
            collation: includesEngineOptions ? options.collation : nil,
            ifNotExists: options.ifNotExists
        )

        return CreateTablePlan(
            definition: definition,
            indexes: resolvedIndexes.map { $0.toPlugin() },
            issues: issues
        )
    }

    // MARK: - Columns

    /// A column the user marked auto-increment without ticking Primary Key is promoted here rather
    /// than in each driver. The old code passed the promotion through `primaryKeyColumns` only, and
    /// SQLite reads `isPrimaryKey` alone, so on SQLite that column got neither a primary key nor
    /// `AUTOINCREMENT`. Reconciling the two once leaves every driver reading one answer.
    private static func resolveColumns(
        _ columns: [EditableColumnDefinition],
        into issues: inout [SchemaDraftIssue]
    ) -> [EditableColumnDefinition] {
        var resolved: [EditableColumnDefinition] = []
        var sourceRows: [Int] = []

        for (row, column) in columns.enumerated() {
            let name = column.name.trimmingCharacters(in: .whitespaces)
            let type = column.dataType.trimmingCharacters(in: .whitespaces)
            if name.isEmpty, type.isEmpty {
                continue
            }
            if name.isEmpty {
                issues.append(SchemaDraftIssue(
                    tab: .columns, row: row, message: String(localized: "This column needs a name.")
                ))
                continue
            }
            if type.isEmpty {
                issues.append(SchemaDraftIssue(
                    tab: .columns, row: row, message: String(localized: "This column needs a type.")
                ))
                continue
            }
            var normalized = column
            normalized.name = name
            normalized.dataType = type
            resolved.append(normalized)
            sourceRows.append(row)
        }

        if resolved.contains(where: { $0.isPrimaryKey }) == false,
           resolved.contains(where: { $0.autoIncrement }) {
            for index in resolved.indices where resolved[index].autoIncrement {
                resolved[index].isPrimaryKey = true
                resolved[index].isNullable = false
            }
        }

        for position in duplicatePositions(of: resolved.map(\.name)) {
            issues.append(SchemaDraftIssue(
                tab: .columns, row: sourceRows[position],
                message: String(
                    format: String(localized: "Another column is already named %@."), resolved[position].name
                )
            ))
        }

        return resolved
    }

    // MARK: - Indexes

    /// An index does need a name, unlike a foreign key: `CREATE INDEX` has nowhere to put an
    /// anonymous one. So the missing name is reported rather than required in silence.
    private static func resolveIndexes(
        _ indexes: [EditableIndexDefinition],
        columnNames: Set<String>,
        into issues: inout [SchemaDraftIssue]
    ) -> [EditableIndexDefinition] {
        var resolved: [EditableIndexDefinition] = []
        var sourceRows: [Int] = []

        for (row, index) in indexes.enumerated() {
            let name = index.name.trimmingCharacters(in: .whitespaces)
            let columns = index.columns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if name.isEmpty, columns.isEmpty, trimmedOrNil(index.whereClause) == nil {
                continue
            }
            if columns.isEmpty {
                issues.append(SchemaDraftIssue(
                    tab: .indexes, row: row,
                    message: String(localized: "This index needs at least one column.")
                ))
                continue
            }
            if name.isEmpty {
                issues.append(SchemaDraftIssue(
                    tab: .indexes, row: row, message: String(localized: "This index needs a name.")
                ))
                continue
            }
            if let unknown = columns.first(where: { !columnNames.contains($0) }) {
                issues.append(SchemaDraftIssue(
                    tab: .indexes, row: row,
                    message: String(
                        format: String(localized: "The table has no column named %@."), unknown
                    )
                ))
                continue
            }
            var normalized = index
            normalized.name = name
            normalized.columns = columns
            resolved.append(normalized)
            sourceRows.append(row)
        }

        for position in duplicatePositions(of: resolved.map(\.name)) {
            issues.append(SchemaDraftIssue(
                tab: .indexes, row: sourceRows[position],
                message: String(
                    format: String(localized: "Another index is already named %@."), resolved[position].name
                )
            ))
        }

        return resolved
    }

    // MARK: - Foreign keys

    private static func resolveForeignKeys(
        _ foreignKeys: [EditableForeignKeyDefinition],
        columnNames: Set<String>,
        dialect: ForeignKeyDialect,
        into issues: inout [SchemaDraftIssue]
    ) -> [EditableForeignKeyDefinition] {
        var resolved: [EditableForeignKeyDefinition] = []
        var sourceRows: [Int] = []

        for (row, foreignKey) in foreignKeys.enumerated() {
            guard let normalized = resolveForeignKey(
                foreignKey, row: row, columnNames: columnNames, dialect: dialect, into: &issues
            ) else { continue }
            resolved.append(normalized)
            sourceRows.append(row)
        }

        let names = resolved.map(\.name)
        for position in duplicatePositions(of: names) where !names[position].isEmpty {
            issues.append(SchemaDraftIssue(
                tab: .foreignKeys, row: sourceRows[position],
                message: String(
                    format: String(localized: "Another foreign key is already named %@."),
                    resolved[position].name
                )
            ))
        }

        return resolved
    }

    /// The constraint name is deliberately absent from every test here. It is optional in every
    /// dialect TablePro speaks, three drivers discard it, and demanding it is what deleted the
    /// user's foreign keys.
    private static func resolveForeignKey(
        _ foreignKey: EditableForeignKeyDefinition,
        row: Int,
        columnNames: Set<String>,
        dialect: ForeignKeyDialect,
        into issues: inout [SchemaDraftIssue]
    ) -> EditableForeignKeyDefinition? {
        var normalized = foreignKey
        normalized.name = foreignKey.name.trimmingCharacters(in: .whitespaces)
        normalized.columns = trimmedList(foreignKey.columns)
        normalized.referencedTable = foreignKey.referencedTable.trimmingCharacters(in: .whitespaces)
        normalized.referencedColumns = trimmedList(foreignKey.referencedColumns)
        normalized.referencedSchema = trimmedOrNil(foreignKey.referencedSchema)

        let isUntouched = normalized.name.isEmpty
            && normalized.columns.isEmpty
            && normalized.referencedTable.isEmpty
            && normalized.referencedColumns.isEmpty
            && normalized.referencedSchema == nil
            && normalized.onDelete == .noAction
            && normalized.onUpdate == .noAction
        if isUntouched {
            return nil
        }

        func report(_ message: String) {
            issues.append(SchemaDraftIssue(tab: .foreignKeys, row: row, message: message))
        }

        if normalized.columns.isEmpty {
            report(String(localized: "This foreign key needs at least one column."))
            return nil
        }
        if let unknown = normalized.columns.first(where: { !columnNames.contains($0) }) {
            report(String(format: String(localized: "The table has no column named %@."), unknown))
            return nil
        }
        if normalized.referencedTable.isEmpty {
            report(String(localized: "This foreign key needs a referenced table."))
            return nil
        }
        if normalized.referencedColumns.isEmpty, !dialect.allowsOmittedReferencedColumns {
            report(String(localized: "This foreign key needs the columns it references."))
            return nil
        }
        if !normalized.referencedColumns.isEmpty,
           normalized.referencedColumns.count != normalized.columns.count {
            report(String(
                localized: "A foreign key needs as many referenced columns as it has columns."
            ))
            return nil
        }
        if normalized.referencedSchema != nil, !dialect.allowsQualifiedReferencedTable {
            report(String(localized: "This database cannot reference a table in another schema."))
            return nil
        }
        if !dialect.supportsDelete(normalized.onDelete) {
            report(String(
                format: String(localized: "This database does not support ON DELETE %@."),
                normalized.onDelete.rawValue
            ))
            return nil
        }
        if !dialect.supportsUpdate(normalized.onUpdate) {
            report(dialect.updateActions.isEmpty
                ? String(localized: "This database has no ON UPDATE action on a foreign key.")
                : String(
                    format: String(localized: "This database does not support ON UPDATE %@."),
                    normalized.onUpdate.rawValue
                ))
            return nil
        }

        return normalized
    }

    // MARK: - Helpers

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func trimmedList(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Every position after the first that repeats a name already seen, so the row the user is most
    /// likely still editing is the one flagged.
    ///
    /// These are positions in the resolved list, not grid rows. A row skipped for being blank or
    /// incomplete shortens the list, so the caller maps them back through its own `sourceRows` or
    /// the message points at a different row than the duplicate.
    private static func duplicatePositions(of names: [String]) -> [Int] {
        var seen: Set<String> = []
        var duplicates: [Int] = []
        for (row, name) in names.enumerated() {
            if seen.contains(name) {
                duplicates.append(row)
            } else {
                seen.insert(name)
            }
        }
        return duplicates
    }
}
