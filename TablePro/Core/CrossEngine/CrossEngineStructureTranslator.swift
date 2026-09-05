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
//  Same-family pairs return the snapshot they were given, byte for byte. A
//  MySQL to MariaDB copy runs the path it always ran, which is the only way a
//  change this wide can be trusted not to move what already worked.
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
        to target: DatabaseType
    ) -> Result {
        let targetFamily = SQLTypeFamily.of(target)
        guard SQLTypeFamily.needsTranslation(from: source, to: target) else {
            let kinds = kinds(of: snapshot, family: targetFamily)
            return Result(
                snapshot: snapshot,
                notes: [],
                sourceKinds: kinds,
                targetKinds: kinds,
                translated: false
            )
        }

        let sourceFamily = SQLTypeFamily.of(source)
        var notes: [CrossEngineConversionNote] = []
        var sourceKindsByColumn: [String: CanonicalTypeKind] = [:]
        var kindsByColumn: [String: CanonicalTypeKind] = [:]
        let keyColumns = Set(snapshot.primaryKeyColumns.map { $0.lowercased() })
        let indexed = Set(
            snapshot.indexes.flatMap(\.columns).map { $0.lowercased() }
        ).union(keyColumns)

        var columns: [EditableColumnDefinition] = []
        for column in snapshot.columns {
            let outcome = translate(
                column,
                table: snapshot.name,
                from: sourceFamily,
                to: targetFamily,
                isKeyColumn: keyColumns.contains(column.name.lowercased())
            )
            columns.append(outcome.column)
            sourceKindsByColumn[outcome.column.name] = outcome.sourceKind
            kindsByColumn[outcome.column.name] = outcome.targetKind
            notes += outcome.notes
        }

        let unboundedIndexColumns = Set(
            columns
                .filter { indexed.contains($0.name.lowercased()) && isUnbounded(kindsByColumn[$0.name]) }
                .map { $0.name.lowercased() }
        )
        let indexOutcome = CrossEngineIndexTranslator.translate(
            snapshot.indexes,
            table: snapshot.name,
            to: targetFamily,
            unboundedColumns: unboundedIndexColumns
        )
        notes += indexOutcome.notes

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

    /// What the columns of a table already on the target hold, for a copy that appends into it
    /// rather than creating it. The same answer the translation produces, read from the other side.
    internal static func kinds(
        of snapshot: TableStructureSnapshot,
        family: SQLTypeFamily
    ) -> [String: CanonicalTypeKind] {
        var kinds: [String: CanonicalTypeKind] = [:]
        for column in snapshot.columns {
            kinds[column.name] = SQLTypeParser.parse(column.dataType, family: family).kind
        }
        return kinds
    }

    // MARK: - Columns

    private struct ColumnOutcome {
        let column: EditableColumnDefinition
        let sourceKind: CanonicalTypeKind
        let targetKind: CanonicalTypeKind
        let notes: [CrossEngineConversionNote]
    }

    private static func translate(
        _ column: EditableColumnDefinition,
        table: String,
        from sourceFamily: SQLTypeFamily,
        to targetFamily: SQLTypeFamily,
        isKeyColumn: Bool
    ) -> ColumnOutcome {
        let canonical = SQLTypeParser.parse(column.dataType, family: sourceFamily)
        var rendered = SQLTypeRenderer.render(canonical, family: targetFamily)
        var notes: [CrossEngineConversionNote] = []

        if isKeyColumn, let bounded = boundedKeyType(rendered, kind: canonical.kind, family: targetFamily) {
            rendered = bounded
        }

        var translated = column
        translated.dataType = rendered.spelling
        translated.unsigned = targetFamily == .mysql && canonical.isUnsigned
        /// Both name a source-side object. A `utf8mb4_0900_ai_ci` collation does not exist anywhere
        /// but MySQL 8, and a character set clause is MySQL syntax outright.
        translated.charset = nil
        translated.collation = nil
        translated.extra = nil
        /// `ON UPDATE CURRENT_TIMESTAMP` is MySQL's alone; no other engine has a column-level one.
        translated.onUpdate = targetFamily == .mysql ? column.onUpdate : nil

        if rendered.fidelity != .exact, let reason = rendered.reason {
            notes.append(CrossEngineConversionNote(
                table: table,
                subject: column.name,
                summary: "\(column.name): \(column.dataType) → \(rendered.spelling)",
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
            column.defaultValue, kind: canonical.kind, to: targetFamily
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

        /// Read back out of what was actually written, not carried over from what was read. The
        /// renderer is the only thing that knows what it chose, and a spelling that lost a time
        /// zone or turned an array into JSON has to say so or the coercer works from the wrong
        /// side of the crossing.
        let targetKind = SQLTypeParser.parse(rendered.spelling, family: targetFamily).kind
        return ColumnOutcome(
            column: translated, sourceKind: canonical.kind, targetKind: targetKind, notes: notes
        )
    }

    // MARK: - Keys

    /// A key column cannot be unbounded text on the engines whose index entries are size-limited.
    /// MySQL refuses `PRIMARY KEY` on a `LONGTEXT` outright, SQL Server caps a key at 900 bytes and
    /// Oracle cannot index a `CLOB` at all, so the `CREATE TABLE` fails rather than the copy losing
    /// anything. A bounded spelling is used for those columns instead, which is why it is a note.
    private static func boundedKeyType(
        _ rendered: RenderedColumnType,
        kind: CanonicalTypeKind,
        family: SQLTypeFamily
    ) -> RenderedColumnType? {
        guard isUnbounded(kind) else { return nil }
        let spelling: String
        switch family {
        case .mysql:
            spelling = isBinary(kind) ? "VARBINARY(255)" : "VARCHAR(255)"
        case .mssql:
            spelling = isBinary(kind) ? "VARBINARY(450)" : "NVARCHAR(450)"
        case .oracle:
            spelling = isBinary(kind) ? "RAW(2000)" : "VARCHAR2(2000)"
        case .postgres, .sqlite, .clickhouse, .duckdb, .generic:
            return nil
        }
        return RenderedColumnType(
            spelling: spelling,
            fidelity: .approximated,
            reason: String(
                format: String(
                    localized: "A key column cannot be unbounded here, so it is created as %@."
                ),
                spelling
            )
        )
    }

    private static func isUnbounded(_ kind: CanonicalTypeKind?) -> Bool {
        switch kind {
        case .text(let length, _), .binary(let length, _): return length == nil
        case .json, .xml, .spatial, .array: return true
        default: return false
        }
    }

    private static func isBinary(_ kind: CanonicalTypeKind) -> Bool {
        guard case .binary = kind else { return false }
        return true
    }
}
