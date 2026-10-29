//
//  CreateTableDraftBuilder.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// The statements a Create Table draft will run, and every row that is not ready to.
struct CreateTablePlan {
    // Never carries indexes or check constraints: each is its own statement after the CREATE.
    let definition: PluginCreateTableDefinition?
    let indexes: [PluginIndexDefinition]
    let issues: [SchemaDraftIssue]
    // Nil writes no comment. Set after the CREATE, as its own statement.
    var tableComment: String?
    var checkConstraints: [PluginCheckConstraintDefinition] = []
    // Working-list rows of `indexes` and `checkConstraints`, since blank and incomplete rows are skipped.
    var indexRows: [Int] = []
    var checkConstraintRows: [Int] = []

    var isReadyToCreate: Bool { definition != nil && issues.isEmpty }

    func indexRow(at position: Int) -> Int {
        indexRows.indices.contains(position) ? indexRows[position] : position
    }

    func checkConstraintRow(at position: Int) -> Int {
        checkConstraintRows.indices.contains(position) ? checkConstraintRows[position] : position
    }
}

// Turns the working rows into a plan. This type says whether a row is complete, the driver how to spell it, and
// `ForeignKeyDialect` what the engine's grammar takes. A blank row is ignored (the editor seeds them), a begun one
// that cannot run is an issue, never a silent drop: requiring a foreign key's name once dropped every key (#2691).
@MainActor
enum CreateTableDraftBuilder {
    // Indexes and checks are never folded into the CREATE: SQLite steps one statement per execute.
    static func plan(
        tableName: String,
        options: CreateTableOptions,
        columns: [EditableColumnDefinition],
        indexes: [EditableIndexDefinition],
        foreignKeys: [EditableForeignKeyDefinition],
        checkConstraints: [EditableCheckConstraintDefinition] = [],
        dialect: ForeignKeyDialect,
        includesEngineOptions: Bool,
        defaults: CreateTableOptionDefaults = CreateTableOptionDefaults(),
        suppliesItsOwnKey: Bool = false
    ) -> CreateTablePlan {
        var issues: [SchemaDraftIssue] = []

        let resolvedColumns = resolveColumns(columns, into: &issues)
        let columnNames = Set(resolvedColumns.map(\.name))
        let resolvedIndexes = resolveIndexes(indexes, columnNames: columnNames, into: &issues)
        let resolvedForeignKeys = resolveForeignKeys(
            foreignKeys, columnNames: columnNames, dialect: dialect, into: &issues
        )
        let resolvedChecks = resolveCheckConstraints(checkConstraints, into: &issues)

        let trimmedName = tableName.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            issues.append(SchemaDraftIssue(
                section: .columns, row: nil, message: String(localized: "The table needs a name.")
            ))
        }
        if resolvedColumns.isEmpty, !suppliesItsOwnKey {
            issues.append(SchemaDraftIssue(
                section: .columns, row: nil,
                message: String(localized: "The table needs at least one column with a name and a type.")
            ))
        }

        guard !trimmedName.isEmpty, !resolvedColumns.isEmpty || suppliesItsOwnKey else {
            return CreateTablePlan(definition: nil, indexes: [], issues: issues)
        }

        let primaryKeyColumns = resolvedColumns.filter(\.isPrimaryKey).map(\.name)
        let characterSet = includesEngineOptions ? defaults.characterSetClause(for: options) : nil
        let definition = PluginCreateTableDefinition(
            tableName: trimmedName,
            columns: resolvedColumns.map { $0.toPlugin() },
            indexes: [],
            foreignKeys: resolvedForeignKeys.map { $0.toPlugin() },
            primaryKeyColumns: primaryKeyColumns,
            engine: includesEngineOptions ? defaults.engineClause(for: options) : nil,
            charset: characterSet?.charset,
            collation: characterSet?.collation,
            ifNotExists: options.ifNotExists
        )

        return CreateTablePlan(
            definition: definition,
            indexes: resolvedIndexes.map { $0.definition.toPlugin() },
            issues: issues,
            tableComment: ObjectCommentDraft.normalized(options.comment),
            checkConstraints: resolvedChecks.map { $0.definition.toPlugin() },
            indexRows: resolvedIndexes.map(\.row),
            checkConstraintRows: resolvedChecks.map(\.row)
        )
    }

    // MARK: - Columns

    // An auto-increment column with no primary key ticked is promoted here, once: SQLite reads `isPrimaryKey` alone.
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
                    section: .columns, row: row, message: String(localized: "This column needs a name.")
                ))
                continue
            }
            if type.isEmpty {
                issues.append(SchemaDraftIssue(
                    section: .columns, row: row, message: String(localized: "This column needs a type.")
                ))
                continue
            }
            if !column.isNullable, column.hasNullDefault {
                issues.append(SchemaDraftIssue(
                    section: .columns, row: row,
                    message: String(localized: "This column does not allow NULL, so its default cannot be NULL.")
                ))
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
                resolved[index].setNullable(false)
            }
        }

        for position in duplicatePositions(of: resolved.map(\.name)) {
            issues.append(SchemaDraftIssue(
                section: .columns, row: sourceRows[position],
                message: String(
                    format: String(localized: "Another column is already named %@."), resolved[position].name
                )
            ))
        }

        return resolved
    }

    // MARK: - Indexes

    // Unlike a foreign key, an index needs a name: CREATE INDEX has nowhere to put an anonymous one.
    private static func resolveIndexes(
        _ indexes: [EditableIndexDefinition],
        columnNames: Set<String>,
        into issues: inout [SchemaDraftIssue]
    ) -> [Resolved<EditableIndexDefinition>] {
        var resolved: [Resolved<EditableIndexDefinition>] = []

        for (row, index) in indexes.enumerated() {
            let name = index.name.trimmingCharacters(in: .whitespaces)
            let columns = index.columns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if name.isEmpty, columns.isEmpty, trimmedOrNil(index.whereClause) == nil {
                continue
            }
            if columns.isEmpty {
                issues.append(SchemaDraftIssue(
                    section: .indexes, row: row,
                    message: String(localized: "This index needs at least one column.")
                ))
                continue
            }
            if name.isEmpty {
                issues.append(SchemaDraftIssue(
                    section: .indexes, row: row, message: String(localized: "This index needs a name.")
                ))
                continue
            }
            var normalized = index
            normalized.name = name
            normalized.columns = columns
            if let unknown = normalized.referencedColumnNames.first(where: { !columnNames.contains($0) }) {
                issues.append(SchemaDraftIssue(
                    section: .indexes, row: row,
                    message: String(
                        format: String(localized: "The table has no column named %@."), unknown
                    )
                ))
                continue
            }
            resolved.append(Resolved(definition: normalized, row: row))
        }

        for position in duplicatePositions(of: resolved.map(\.definition.name)) {
            issues.append(SchemaDraftIssue(
                section: .indexes, row: resolved[position].row,
                message: String(
                    format: String(localized: "Another index is already named %@."),
                    resolved[position].definition.name
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
                section: .foreignKeys, row: sourceRows[position],
                message: String(
                    format: String(localized: "Another foreign key is already named %@."),
                    resolved[position].name
                )
            ))
        }

        return resolved
    }

    // No test here demands the name: it is optional in every dialect, and demanding it deleted the user's keys.
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
            issues.append(SchemaDraftIssue(section: .foreignKeys, row: row, message: message))
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

    // MARK: - Check constraints

    // Every driver writes a check as ADD CONSTRAINT <name> CHECK (<expression>), so both are required.
    private static func resolveCheckConstraints(
        _ constraints: [EditableCheckConstraintDefinition],
        into issues: inout [SchemaDraftIssue]
    ) -> [Resolved<EditableCheckConstraintDefinition>] {
        var resolved: [Resolved<EditableCheckConstraintDefinition>] = []

        for (row, constraint) in constraints.enumerated() {
            let name = constraint.name.trimmingCharacters(in: .whitespaces)
            let expression = constraint.expression.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty, expression.isEmpty {
                continue
            }
            if expression.isEmpty {
                issues.append(SchemaDraftIssue(
                    section: .checkConstraints, row: row,
                    message: String(localized: "This check constraint needs an expression.")
                ))
                continue
            }
            if name.isEmpty {
                issues.append(SchemaDraftIssue(
                    section: .checkConstraints, row: row,
                    message: String(localized: "This check constraint needs a name.")
                ))
                continue
            }
            var normalized = constraint
            normalized.name = name
            normalized.expression = expression
            resolved.append(Resolved(definition: normalized, row: row))
        }

        for position in duplicatePositions(of: resolved.map(\.definition.name)) {
            issues.append(SchemaDraftIssue(
                section: .checkConstraints, row: resolved[position].row,
                message: String(
                    format: String(localized: "Another check constraint is already named %@."),
                    resolved[position].definition.name
                )
            ))
        }

        return resolved
    }

    // MARK: - Helpers

    private struct Resolved<Definition> {
        let definition: Definition
        let row: Int
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func trimmedList(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // Positions in the resolved list after the first that repeat a name, so the row likely still being edited is
    // flagged. The caller maps them back to working rows: skipped rows shorten the list.
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
