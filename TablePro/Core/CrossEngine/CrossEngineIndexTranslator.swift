//
//  CrossEngineIndexTranslator.swift
//  TablePro
//
//  Which of a table's indexes survive the crossing, and in what shape.
//
//  An index is the part of a copy that fails loudest. A `GIN` index arrives at
//  MySQL as a plain `INDEX` over a column that is now `JSON`, and MySQL refuses
//  the whole `CREATE TABLE` for it; an index over a column that became
//  `LONGTEXT` is refused with "used in key specification without a key length",
//  and one over two `VARCHAR(500)` columns with "Specified key was too long".
//  Each takes the table down with it, so an index that cannot be written as it
//  was is cut to prefixes or dropped here, and named in the review instead.
//

import Foundation
import TableProPluginKit

internal enum CrossEngineIndexTranslator {
    internal struct Result: Sendable {
        internal let indexes: [EditableIndexDefinition]
        internal let notes: [CrossEngineConversionNote]
    }

    /// `columnKinds` is what each column holds on the target, keyed by its name in lowercase.
    internal static func translate(
        _ indexes: [EditableIndexDefinition],
        table: String,
        to family: SQLTypeFamily,
        columnKinds: [String: CanonicalTypeKind]
    ) -> Result {
        var kept: [EditableIndexDefinition] = []
        var notes: [CrossEngineConversionNote] = []

        for index in indexes {
            /// The primary key is not an index the target creates separately: it comes out of
            /// `primaryKeyColumns` inside the `CREATE TABLE`, and the column translation has
            /// already bounded whatever it needed to.
            guard !index.isPrimary else {
                kept.append(index)
                continue
            }
            guard let translated = translate(
                index, table: table, to: family, columnKinds: columnKinds, notes: &notes
            ) else { continue }
            kept.append(translated)
        }
        return Result(indexes: kept, notes: notes)
    }

    private static func translate(
        _ index: EditableIndexDefinition,
        table: String,
        to family: SQLTypeFamily,
        columnKinds: [String: CanonicalTypeKind],
        notes: inout [CrossEngineConversionNote]
    ) -> EditableIndexDefinition? {
        guard supportsSecondaryIndexes(family) else {
            notes.append(dropped(index, table: table, reason: String(
                localized: "This engine does not take a secondary index in a CREATE TABLE."
            )))
            return nil
        }

        guard let type = translatedType(index.type, family: family) else {
            notes.append(dropped(index, table: table, reason: String(
                format: String(localized: "A %@ index has no equivalent on this engine."),
                index.type.rawValue
            )))
            return nil
        }

        let unbounded = index.columns.filter { CrossEngineKeyWidth.isUnbounded(columnKinds[$0.lowercased()]) }
        if !unbounded.isEmpty, !supportsKeyPrefixes(family) {
            notes.append(dropped(index, table: table, reason: String(
                format: String(
                    localized: "%@ is unbounded text or binary here, which this engine cannot index."
                ),
                unbounded.joined(separator: ", ")
            )))
            return nil
        }

        var translated = index
        translated.type = type
        /// Carried to an engine without key prefixes the number is ignored by its driver, so it is
        /// not carried at all.
        translated.columnPrefixes = [:]
        if supportsKeyPrefixes(family) {
            guard let prefixes = CrossEngineKeyWidth.mysqlPrefixes(
                columns: index.columns, declared: index.columnPrefixes, kinds: columnKinds
            ) else {
                notes.append(dropped(index, table: table, reason: String(
                    localized: "Its columns pass the 3,072 bytes this engine can index, even with each cut to a prefix."
                )))
                return nil
            }
            translated.columnPrefixes = prefixes
            let cut = index.columns.filter { prefixes[$0] != index.columnPrefixes[$0] }
            if !cut.isEmpty, index.isUnique {
                notes.append(uniqueOnPrefix(index, table: table, columns: cut))
            }
        }
        /// A partial index is PostgreSQL's, SQLite's and DuckDB's syntax. Elsewhere the clause is
        /// dropped and the index becomes a full one, which indexes more rather than less.
        if index.whereClause?.nilIfEmpty != nil, !supportsPartialIndexes(family) {
            translated.whereClause = nil
            notes.append(CrossEngineConversionNote(
                table: table,
                subject: index.name,
                summary: String(
                    format: String(localized: "%@ stops being a partial index"), index.name
                ),
                reason: String(
                    localized: "Its WHERE clause is not supported here, so it covers every row."
                ),
                fidelity: .approximated
            ))
        }
        return translated
    }

    /// A prefix on a unique index is not the same constraint. Two rows differing only after the
    /// prefix collide, so the copy fails part way through the data phase on a table the source
    /// considered valid, and where the rows do fit the target enforces less than the source did.
    private static func uniqueOnPrefix(
        _ index: EditableIndexDefinition,
        table: String,
        columns: [String]
    ) -> CrossEngineConversionNote {
        CrossEngineConversionNote(
            table: table,
            subject: index.name,
            summary: String(
                format: String(localized: "%1$@ becomes unique on the first %2$lld characters"),
                index.name, CrossEngineKeyWidth.prefixLength
            ),
            reason: String(
                format: String(
                    localized: "%@ is too wide for this engine to index whole, so only a prefix is indexed. Rows differing only past it are refused as duplicates."
                ),
                columns.joined(separator: ", ")
            ),
            fidelity: .approximated
        )
    }

    private static func dropped(
        _ index: EditableIndexDefinition,
        table: String,
        reason: String
    ) -> CrossEngineConversionNote {
        CrossEngineConversionNote(
            table: table,
            subject: index.name,
            summary: String(format: String(localized: "The index %@ is left out"), index.name),
            reason: reason,
            fidelity: .approximated
        )
    }

    // MARK: - Family rules

    /// ClickHouse's `CREATE TABLE` takes a sorting key and data-skipping indexes, neither of which
    /// is what a b-tree index from another engine means, and its driver writes neither.
    private static func supportsSecondaryIndexes(_ family: SQLTypeFamily) -> Bool {
        family != .clickhouse
    }

    private static func supportsKeyPrefixes(_ family: SQLTypeFamily) -> Bool {
        family == .mysql
    }

    private static func supportsPartialIndexes(_ family: SQLTypeFamily) -> Bool {
        family == .postgres || family == .sqlite || family == .duckdb
    }

    private static func translatedType(
        _ type: EditableIndexDefinition.IndexType,
        family: SQLTypeFamily
    ) -> EditableIndexDefinition.IndexType? {
        switch type {
        case .btree:
            return .btree
        case .hash:
            return family == .mysql || family == .postgres ? .hash : .btree
        case .fulltext, .spatial:
            return family == .mysql ? type : nil
        case .gin, .gist, .brin:
            return family == .postgres ? type : nil
        }
    }
}
