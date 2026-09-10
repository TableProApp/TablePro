//
//  ObjectCopyTableDraft.swift
//  TablePro
//
//  One table's decisions, and the two statements they produce.
//
//  Split out of `ObjectCopyPlanner`, which reached its length limit. The
//  planner resolves and reads; everything here is what one table resolved to,
//  so the two scoped calls that follow can each run over the whole list.
//

import Foundation
import TableProPluginKit

/// One table's decisions, made before any driver is opened so the two scoped calls that follow can
/// each run over the whole list.
internal struct ObjectCopyTableDraft {
    let selection: ObjectCopySelection
    let snapshot: TableStructureSnapshot
    /// The same table said in the target's own types, which is what the target driver is handed.
    /// Identical to `snapshot` whenever the two engines share a type family.
    let targetStructure: TableStructureSnapshot
    let sourceSchema: String?
    let targetSchema: String?
    let targetTable: String
    /// Read with these, written with those. A case-insensitive match pairs two spellings of one
    /// column, and each side has to be quoted the way its own server spells it.
    let sourceColumns: [String]
    let targetColumns: [String]
    let writesStructure: Bool
    let dropsFirst: Bool
    let emptiesFirst: Bool
    let copiesData: Bool
    let copiesIdentityColumn: Bool
    /// True when the two engines do not share a type family, so the structure was rewritten and
    /// the values need reshaping on the way in.
    let isCrossEngine: Bool
    let conversionNotes: [CrossEngineConversionNote]
    let coercer: CrossEngineValueCoercer?
    /// The `WHERE` and row limit the user set on this table, or nil for every row.
    let rowScope: PluginExportRowScope?
    let note: String?

    init(
        selection: ObjectCopySelection,
        read: TableStructureRead,
        snapshot: TableStructureSnapshot,
        targetSnapshot: TableStructureSnapshot?,
        existsInTarget: Bool,
        sourceSchema: String?,
        targetSchema: String?,
        request: ObjectCopyRequest
    ) {
        self.selection = selection
        self.snapshot = snapshot
        self.rowScope = request.rowScope(for: selection)
        self.sourceSchema = sourceSchema
        /// Never the source's. A target endpoint that names no schema means the target driver's
        /// own current scope, and inheriting the source's put a SQL Server `dbo` into a MySQL
        /// INSERT, naming a database that engine does not have.
        self.targetSchema = targetSchema

        let keepsTargetStructure = existsInTarget && request.existingPolicy != .replace
        let writesStructure = request.content.includesStructure && !keepsTargetStructure
        self.writesStructure = writesStructure
        self.dropsFirst = writesStructure && existsInTarget

        /// The target's own name when it already has the table, because a case-insensitive match
        /// pairs `Orders` with `orders` and the INSERT has to quote the one that exists.
        self.targetTable = (writesStructure ? nil : targetSnapshot?.name) ?? snapshot.name

        let translation = CrossEngineStructureTranslator.translate(
            snapshot, from: request.source.databaseType, to: request.target.databaseType
        )
        self.targetStructure = translation.snapshot
        self.isCrossEngine = translation.translated
        /// Only a run that writes the structure has anything to report about it. Appending into a
        /// table the target already has changes no type, so a list of conversions would describe
        /// DDL that is not going to run.
        self.conversionNotes = writesStructure ? translation.notes : []

        /// Read from the driver's own columns rather than from the snapshot. SQL Server computed
        /// columns and ClickHouse ALIAS columns set `isGenerated` with no expression, and
        /// PostgreSQL reports identity through `identityKind`; the snapshot conversion keeps
        /// neither, so those columns looked ordinary and writable.
        ///
        /// A computed column is the exception once the engines differ: its expression cannot come
        /// across, so the copy creates it as an ordinary column, and a column the target will never
        /// compute has to be written or it arrives empty.
        let carriesGeneratedColumns = translation.translated && writesStructure
        let pairs = Self.writableColumnPairs(
            columns: read.columns,
            snapshot: carriesGeneratedColumns ? translation.snapshot : snapshot,
            targetSnapshot: writesStructure ? nil : targetSnapshot,
            includesGenerated: carriesGeneratedColumns
        )
        self.sourceColumns = pairs.map(\.source)
        self.targetColumns = pairs.map(\.target)
        let copiesData = request.content.includesData && !pairs.isEmpty && (writesStructure || existsInTarget)
        self.copiesData = copiesData

        /// A data-only replace has no DROP and CREATE to clear the table, so it is emptied instead,
        /// and only where rows are going back into it. Emptying without that condition deleted
        /// every row of a table whose columns the target does not share, and then wrote nothing:
        /// the step was dropped from the data phase for having no writable column while its DELETE
        /// stayed in the clear phase, and the review said only that the two sides shared no column.
        self.emptiesFirst = copiesData
            && existsInTarget
            && request.existingPolicy == .replace
            && !writesStructure

        let written = Set(pairs.map { $0.source.lowercased() })
        self.copiesIdentityColumn = request.content.includesData && read.columns.contains {
            written.contains($0.name.lowercased()) && ($0.isIdentity || $0.extra?.lowercased().contains("auto_increment") == true)
        }

        /// Built from whichever side decides the target's types: the translation when the copy
        /// creates the table, and the target's own structure when it appends into one that is
        /// already there and whose columns the user may have declared differently.
        self.coercer = Self.coercer(
            for: pairs,
            translation: translation,
            targetSnapshot: writesStructure ? nil : targetSnapshot,
            request: request
        )

        if request.content.includesData, !writesStructure, !existsInTarget {
            self.note = String(
                localized: "The target has no table of this name, so the rows have nowhere to go."
            )
        } else if request.content.includesData, pairs.isEmpty {
            self.note = String(localized: "The source and the target share no writable column.")
        } else {
            self.note = nil
        }
    }

    /// The columns the copy writes, paired source spelling to target spelling.
    ///
    /// The source's own order, without the ones the server computes: an `INSERT` into a generated
    /// column is rejected by every engine that has them. When the target's structure is not being
    /// written the answer narrows to what both sides have, matched without regard to case, because
    /// a column the target lacks cannot be written to and one it has that the source lacks keeps
    /// its default.
    static func writableColumnPairs(
        columns: [PluginColumnInfo],
        snapshot: TableStructureSnapshot,
        targetSnapshot: TableStructureSnapshot?,
        includesGenerated: Bool = false
    ) -> [(source: String, target: String)] {
        let generated = includesGenerated
            ? Set<String>()
            : Set(columns.filter(\.isGenerated).map { $0.name.lowercased() })
        let sourceColumns = snapshot.columns
            .filter { $0.generationExpression == nil && !generated.contains($0.name.lowercased()) }
            .map(\.name)
        guard let targetSnapshot else { return sourceColumns.map { ($0, $0) } }

        /// Exact spellings first. PostgreSQL allows quoted `Orders` and `orders` in one schema, so
        /// folding case unconditionally resolved either to whichever row came back first.
        var exact: [String: String] = [:]
        var folded: [String: [String]] = [:]
        for column in targetSnapshot.columns where column.generationExpression == nil {
            exact[column.name] = column.name
            folded[column.name.lowercased(), default: []].append(column.name)
        }
        return sourceColumns.compactMap { name in
            if let target = exact[name] { return (name, target) }
            guard let candidates = folded[name.lowercased()], candidates.count == 1 else { return nil }
            return (name, candidates[0])
        }
    }

    /// Nil where the two engines share a type family, and nil where the columns that are written
    /// hold nothing whose spelling differs between them. A copy that needs no reshaping runs the
    /// loop it ran before this existed.
    static func coercer(
        for pairs: [(source: String, target: String)],
        translation: CrossEngineStructureTranslator.Result,
        targetSnapshot: TableStructureSnapshot?,
        request: ObjectCopyRequest
    ) -> CrossEngineValueCoercer? {
        guard translation.translated, !pairs.isEmpty else { return nil }
        let source = SQLTypeFamily.of(request.source.databaseType)
        /// The target's own columns when the copy appends into a table that is already there, and
        /// the translation's when it creates one. The user may have declared an existing table's
        /// columns differently from anything this copy would have chosen.
        let declared = targetSnapshot.map {
            CrossEngineStructureTranslator.kinds(
                of: $0, family: SQLTypeFamily.of(request.target.databaseType)
            )
        } ?? translation.targetKinds
        let sourceKinds = folded(translation.sourceKinds)
        let targetKinds = folded(declared)
        let columnPairs = pairs.map {
            CrossEngineValueCoercer.ColumnPair(
                source: sourceKinds[$0.source.lowercased()],
                target: targetKinds[$0.target.lowercased()]
            )
        }
        let coercer = CrossEngineValueCoercer(pairs: columnPairs, from: source)
        return coercer.isNeeded ? coercer : nil
    }

    /// Matched without regard to case, the way the column pairing itself is: PostgreSQL allows
    /// quoted `Orders` and `orders` in one schema and the two sides need not spell one the same.
    private static func folded(
        _ kinds: [String: CanonicalTypeKind]
    ) -> [String: CanonicalTypeKind] {
        var folded: [String: CanonicalTypeKind] = [:]
        for (name, kind) in kinds { folded[name.lowercased()] = kind }
        return folded
    }
}

internal struct ObjectCopyDDLInput: Sendable {
    let id: String
    let snapshot: TableStructureSnapshot
    let targetSchema: String?
    let writesStructure: Bool
    let dropsFirst: Bool
    let emptiesFirst: Bool
    let clearsWithDelete: Bool
}

internal struct ObjectCopyTableDDL: Sendable {
    var drop: [SyncStatement] = []
    var create: [SyncStatement] = []
    var truncate: [SyncStatement] = []
}

internal enum ObjectCopyError: LocalizedError {
    case refused(String)

    internal var errorDescription: String? {
        switch self {
        case .refused(let message): return message
        }
    }
}

/// The read side of a table copy: the exact columns that will be written, in the order they will be
/// written, so the stream and the INSERT cannot drift apart.
internal enum ObjectCopySelectQuery {
    internal static func build(
        columns: [String],
        table: String,
        schema: String?,
        driver: any PluginDatabaseDriver,
        scope: PluginExportRowScope? = nil
    ) -> String {
        let list = columns.isEmpty
            ? "*"
            : columns.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
        var query = "SELECT \(list) FROM \(qualified(table, schema, driver))"
        /// `sanitizedFilter` rather than `filter`. The text is the user's own SQL against their own
        /// connection, but it is spliced into this statement, and the sanitizer is what keeps it to
        /// the single expression the field is for.
        if let filter = scope?.sanitizedFilter, !filter.isEmpty {
            query += " WHERE \(filter)"
        }
        guard let rowLimit = scope?.rowLimit else { return query }
        /// Through the driver's own injection, because `LIMIT` is not the spelling on SQL Server or
        /// on Oracle before 12c.
        return driver.injectRowLimit(query, limit: rowLimit) ?? "\(query) LIMIT \(rowLimit)"
    }

    internal static func qualified(
        _ table: String,
        _ schema: String?,
        _ driver: any PluginDatabaseDriver
    ) -> String {
        guard let schema, !schema.isEmpty else { return driver.quoteIdentifier(table) }
        return "\(driver.quoteIdentifier(schema)).\(driver.quoteIdentifier(table))"
    }
}
