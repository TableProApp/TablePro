//
//  CrossEngineStructureTranslator.swift
//  TablePro
//
//  Says one engine's table in another engine's terms.
//
//  It rewrites nothing the target driver already owns. Quoting, the primary
//  key clause, index and foreign key syntax, `SERIAL` versus `AUTO_INCREMENT`
//  versus `IDENTITY` are all decided by `generateCreateTableSQL` on the target
//  side, and were already correct. What was source-native and reached the
//  target unchanged is the list here: the type spelling, the default
//  expression, the character set, the generation expression and the index
//  kind. Translating exactly those is what turns a refusal into a copy.
//
//  Same-family pairs return the snapshot they were given, byte for byte, apart
//  from an index the target cannot write. A MySQL to MariaDB copy runs the
//  path it always ran, which is the only way a change this wide can be trusted
//  not to move what already worked.
//

import Foundation
import TableProPluginKit

internal enum CrossEngineStructureTranslator {
    internal struct Result: Sendable {
        internal let snapshot: TableStructureSnapshot
        internal let notes: [CrossEngineConversionNote]
        /// What each column held on the source, keyed by the column's name.
        ///
        /// The coercer needs both sides. Which reshaping a value needs is not answerable from
        /// either alone: a boolean has to be recognised on the source, because `t` is boolean only
        /// where the source said so, while a time zone has to be dropped according to the target,
        /// because only the target knows whether it has one.
        internal let sourceKinds: [String: CanonicalTypeKind]
        /// What each written column holds on the target, keyed by the same name.
        ///
        /// Read back out of the spelling the renderer produced rather than carried over from the
        /// source. They are not the same question: a PostgreSQL `timestamptz` is rendered as MySQL
        /// `DATETIME`, which has no zone, and recording the source's answer told the coercer the
        /// target still had one, so the offset it exists to strip was left on every value.
        internal let targetKinds: [String: CanonicalTypeKind]
        /// True when the source's own defaults could not come across as written, so the plan must
        /// not also copy the sequences those defaults named.
        internal let translated: Bool
    }

    internal static func translate(
        _ snapshot: TableStructureSnapshot,
        from source: DatabaseType,
        to target: DatabaseType,
        targetServerVersion: String? = nil
    ) -> Result {
        let targetFamily = SQLTypeFamily.of(target)
        guard SQLTypeFamily.needsTranslation(from: source, to: target) else {
            let kinds = kinds(of: snapshot, family: targetFamily)
            /// A family shares type spellings, not indexes: Redshift reports its `DISTKEY` and
            /// `SORTKEY` as indexes, and PostgreSQL writes an index type it does not know into `USING`.
            let indexOutcome = CrossEngineIndexTranslator.retyped(
                snapshot.indexes, table: snapshot.name, from: source, to: target
            )
            return Result(
                snapshot: replacingIndexes(of: snapshot, with: indexOutcome.indexes),
                notes: indexOutcome.notes,
                sourceKinds: kinds,
                targetKinds: kinds,
                translated: false
            )
        }

        let sourceFamily = SQLTypeFamily.of(source)
        let jsonColumnType = PostgreSQLServerVersion.jsonColumnType(
            for: target, serverVersion: targetServerVersion
        )
        let creatableIndexes = CrossEngineIndexTranslator.creatable(
            snapshot.indexes, table: snapshot.name, from: source, to: target
        )
        let keyColumns = Set(snapshot.primaryKeyColumns.map { $0.lowercased() })
        let indexedColumns = Set(
            creatableIndexes.indexes.filter { !$0.isPrimary }.flatMap(\.columns).map { $0.lowercased() }
        )

        var drafts = snapshot.columns.map { column in
            let canonical = SQLTypeParser.parse(
                column.typeNameForClassification, catalogSpelling: column.ddlSpelling, family: sourceFamily
            )
            return CrossEngineColumnDraft(
                name: column.name,
                isNullable: column.isNullable,
                source: canonical,
                rendered: SQLTypeRenderer.render(canonical, family: targetFamily, jsonColumnType: jsonColumnType),
                family: targetFamily
            )
        }
        let foreignKeys = snapshot.foreignKeys.map(\.columns)
        CrossEngineKeyWidth.boundKeys(
            &drafts, primaryKey: snapshot.primaryKeyColumns, foreignKeys: foreignKeys, family: targetFamily
        )
        if targetFamily == .mysql {
            CrossEngineRowSize.fitMySQLRow(
                &drafts,
                keyColumns: keyColumns,
                referencingColumns: Set(foreignKeys.joined().map { $0.lowercased() }),
                indexedColumns: indexedColumns,
                flavor: MySQLStorageWidth.Flavor.of(target, serverVersion: targetServerVersion)
            )
        }

        var notes: [CrossEngineConversionNote] = []
        var sourceKindsByColumn: [String: CanonicalTypeKind] = [:]
        var kindsByColumn: [String: CanonicalTypeKind] = [:]
        var columns: [EditableColumnDefinition] = []
        for (column, draft) in zip(snapshot.columns, drafts) {
            let outcome = translate(column, draft: draft, table: snapshot.name, to: targetFamily)
            columns.append(outcome.column)
            sourceKindsByColumn[column.name] = draft.source.kind
            kindsByColumn[column.name] = draft.targetKind
            notes += outcome.notes
        }
        if targetFamily == .mssql, let note = utf16LengthNote(for: drafts, table: snapshot.name) {
            notes.append(note)
        }

        var kindsByLowercasedName: [String: CanonicalTypeKind] = [:]
        for draft in drafts { kindsByLowercasedName[draft.name.lowercased()] = draft.targetKind }
        let indexOutcome = CrossEngineIndexTranslator.translate(
            creatableIndexes.indexes,
            table: snapshot.name,
            to: targetFamily,
            columnKinds: kindsByLowercasedName
        )
        notes += creatableIndexes.notes + indexOutcome.notes

        let translated = TableStructureSnapshot(
            name: snapshot.name,
            schema: snapshot.schema,
            columns: columns,
            indexes: indexOutcome.indexes,
            foreignKeys: snapshot.foreignKeys,
            /// `ENGINE=InnoDB`, a MySQL character set and a MySQL collation are all rejected
            /// outright by every other engine's `CREATE TABLE`.
            engine: nil,
            charset: nil,
            collation: nil
        )
        return Result(
            snapshot: translated,
            notes: notes,
            sourceKinds: sourceKindsByColumn,
            targetKinds: kindsByColumn,
            translated: true
        )
    }

    private static func replacingIndexes(
        of snapshot: TableStructureSnapshot,
        with indexes: [EditableIndexDefinition]
    ) -> TableStructureSnapshot {
        guard indexes != snapshot.indexes else { return snapshot }
        return TableStructureSnapshot(
            name: snapshot.name,
            schema: snapshot.schema,
            columns: snapshot.columns,
            indexes: indexes,
            foreignKeys: snapshot.foreignKeys,
            engine: snapshot.engine,
            charset: snapshot.charset,
            collation: snapshot.collation
        )
    }

    /// What the columns of a table already on the target hold, for a copy that appends into it
    /// rather than creating it. The same answer the translation produces, read from the other side.
    internal static func kinds(
        of snapshot: TableStructureSnapshot,
        family: SQLTypeFamily
    ) -> [String: CanonicalTypeKind] {
        var kinds: [String: CanonicalTypeKind] = [:]
        for column in snapshot.columns {
            kinds[column.name] = SQLTypeParser.parse(
                column.typeNameForClassification, catalogSpelling: column.ddlSpelling, family: family
            ).kind
        }
        return kinds
    }

    // MARK: - Columns

    private struct ColumnOutcome {
        let column: EditableColumnDefinition
        let notes: [CrossEngineConversionNote]
    }

    private static func translate(
        _ column: EditableColumnDefinition,
        draft: CrossEngineColumnDraft,
        table: String,
        to targetFamily: SQLTypeFamily
    ) -> ColumnOutcome {
        let rendered = draft.rendered
        var notes: [CrossEngineConversionNote] = []

        var translated = column
        translated.dataType = rendered.spelling
        translated.unsigned = targetFamily == .mysql && draft.source.isUnsigned
        /// Both name a source-side object. A `utf8mb4_0900_ai_ci` collation does not exist anywhere
        /// but MySQL 8, and a character set clause is MySQL syntax outright.
        translated.charset = nil
        translated.collation = nil
        translated.extra = nil
        /// The source server's own spellings name types and functions the target does not have, so
        /// they are dropped even where a rendered name happens to read the same.
        translated.dropCatalogSpellings()
        /// `ON UPDATE CURRENT_TIMESTAMP` is MySQL's alone; no other engine has a column-level one.
        translated.onUpdate = targetFamily == .mysql ? column.onUpdate : nil

        /// Named by the spelling the source was read from, which is the one carrying its length:
        /// `character varying(5000)` says why a key was cut where `CHARACTER VARYING` does not.
        if rendered.fidelity != .exact, let reason = rendered.reason {
            notes.append(CrossEngineConversionNote(
                table: table,
                subject: column.name,
                summary: "\(column.name): \(draft.source.sourceSpelling) → \(rendered.spelling)",
                reason: reason,
                fidelity: rendered.fidelity
            ))
        }

        if let expression = column.generationExpression?.nilIfEmpty {
            translated.generationExpression = nil
            translated.generationKind = nil
            notes.append(CrossEngineConversionNote(
                table: table,
                subject: column.name,
                summary: String(
                    format: String(localized: "%@ stops being a computed column"), column.name
                ),
                reason: String(
                    format: String(
                        localized: "Its expression %@ is written in the source's own dialect, so the column is created as an ordinary one and its values are copied."
                    ),
                    expression
                ),
                fidelity: .approximated
            ))
        }

        let defaultOutcome = CrossEngineDefaultValue.translate(
            column.defaultValue, kind: draft.source.kind, to: targetFamily
        )
        switch defaultOutcome {
        case .none:
            translated.defaultValue = nil
        case .keep(let value):
            translated.defaultValue = value
        case .autoIncrement:
            translated.defaultValue = nil
            translated.autoIncrement = true
        case .drop(let reason):
            translated.defaultValue = nil
            notes.append(CrossEngineConversionNote(
                table: table,
                subject: column.name,
                summary: String(format: String(localized: "%@ loses its default"), column.name),
                reason: reason,
                fidelity: .approximated
            ))
        }

        return ColumnOutcome(column: translated, notes: notes)
    }

    /// SQL Server measures an `NVARCHAR(n)` in UTF-16 code units, and a character outside the Basic
    /// Multilingual Plane, most emoji among them, takes two. Every other engine counts it as one, so
    /// a value that fills its declared length with such characters is refused where it was valid.
    /// The length is kept rather than doubled, because doubling pads every `NCHAR` value to twice its
    /// width and changes what the column accepts for text that never uses one, so the table carries
    /// one note naming the columns instead of one per column.
    private static func utf16LengthNote(
        for drafts: [CrossEngineColumnDraft],
        table: String
    ) -> CrossEngineConversionNote? {
        let bounded = drafts.filter { draft in
            guard case .text(let sourceLength?, _) = draft.source.kind,
                  case .text(let targetLength?, _) = draft.targetKind else { return false }
            return sourceLength == targetLength
        }
        guard !bounded.isEmpty else { return nil }
        return CrossEngineConversionNote(
            table: table,
            subject: "",
            summary: String(
                format: String(localized: "Lengths counted in UTF-16 units: %@"),
                bounded.map(\.name).joined(separator: ", ")
            ),
            reason: String(
                localized: "SQL Server counts most emoji as two characters toward an NVARCHAR length, so a value that fills its length with them is refused."
            ),
            fidelity: .approximated
        )
    }
}
