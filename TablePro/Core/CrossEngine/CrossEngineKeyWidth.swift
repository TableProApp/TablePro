//
//  CrossEngineKeyWidth.swift
//  TablePro
//
//  Whether a key the source could index fits in the target's index entries.
//
//  Judged on the target's types, not the source's. A PostgreSQL
//  `varchar(5000)` is bounded where it is read and unbounded where it is
//  written, as an `NVARCHAR(MAX)` on SQL Server, and a `varchar(1000)` is
//  4,000 bytes on MySQL, past the 3,072 bytes an InnoDB index takes.
//

import Foundation

internal enum CrossEngineKeyWidth {
    /// The length a text key is cut to where the engine needs one. 255 is what MySQL's own tooling
    /// uses, and at four bytes a character three such parts fit in one 3,072-byte key.
    internal static let prefixLength = 255

    // MARK: - Keys

    /// Respells the columns of the primary key and of each foreign key that the target cannot index
    /// as declared.
    ///
    /// A part with no length at all gets a bounded spelling first, because MySQL refuses to key a
    /// `LONGTEXT`, SQL Server an `NVARCHAR(MAX)` and Oracle a `CLOB`, and a foreign key has to match
    /// the key it references. Then, while the key is wider than the engine counts at CREATE, the
    /// widest part is cut to that same bounded length. What is still too wide is settled the
    /// engine's way: MySQL and Oracle share the bytes left between the parts, and SQL Server, which
    /// refuses only fixed-length parts past its limit, gives the widest of those a variable
    /// spelling. A row whose key no longer fits is refused on insert, which is why every respelling
    /// is a note.
    internal static func boundKeys(
        _ columns: inout [CrossEngineColumnDraft],
        primaryKey: [String],
        foreignKeys: [[String]],
        family: SQLTypeFamily
    ) {
        guard let budget = CrossEngineKeyBudget.of(family) else { return }
        fit(&columns, key: primaryKey, limit: budget.primaryKeyBytes, budget: budget)
        for foreignKey in foreignKeys {
            fit(&columns, key: foreignKey, limit: budget.indexesForeignKeys ? budget.indexBytes : nil, budget: budget)
        }
    }

    private static func fit(
        _ columns: inout [CrossEngineColumnDraft],
        key: [String],
        limit: Int?,
        budget: CrossEngineKeyBudget
    ) {
        let names = Set(key.map { $0.lowercased() })
        let parts = columns.indices.filter { names.contains(columns[$0].name.lowercased()) }
        guard !parts.isEmpty else { return }

        for part in parts where budget.partBytes(columns[part].targetKind) == nil {
            let written = columns[part].rendered.spelling
            let spelling = budget.spelling(
                for: columns[part].targetKind, length: budget.boundedLength(of: columns[part].targetKind)
            )
            columns[part].respell(spelling, fidelity: .approximated, reason: String(
                format: String(localized: "%1$@ cannot be part of a key here, so the column is created as %2$@."),
                written, spelling
            ))
        }

        guard let limit else { return }
        cutToBoundedLength(&columns, parts: parts, limit: limit, budget: budget)
        switch budget.check {
        case .declaredWidth:
            shareBytes(&columns, parts: parts, limit: limit, budget: budget)
        case .fixedWidth:
            makeVariableLength(&columns, parts: parts, limit: limit, budget: budget)
        }
    }

    private static func cutToBoundedLength(
        _ columns: inout [CrossEngineColumnDraft],
        parts: [Int],
        limit: Int,
        budget: CrossEngineKeyBudget
    ) {
        while let bytes = budget.declaredBytes(parts.map { columns[$0].targetKind }), bytes > limit {
            let longer = parts.filter { part in
                let kind = columns[part].targetKind
                guard let length = budget.length(of: kind) else { return false }
                return length > budget.boundedLength(of: kind)
            }
            guard let widest = widestPart(longer, in: columns, budget: budget) else { return }
            let kind = columns[widest].targetKind
            cut(&columns[widest], to: budget.spelling(for: kind, length: budget.boundedLength(of: kind)), limit: limit)
        }
    }

    /// Gives each part at most an equal share of the bytes the other parts leave, narrowest first, so
    /// a part narrower than its share keeps its length and passes what it does not use on.
    private static func shareBytes(
        _ columns: inout [CrossEngineColumnDraft],
        parts: [Int],
        limit: Int,
        budget: CrossEngineKeyBudget
    ) {
        guard let bytes = budget.checkedBytes(parts.map { columns[$0].targetKind }), bytes > limit else { return }
        let cuttable = parts.filter { budget.length(of: columns[$0].targetKind) != nil }
        let settledBytes = parts
            .filter { !cuttable.contains($0) }
            .reduce(0) { $0 + (budget.partBytes(columns[$1].targetKind) ?? 0) }
        var remaining = limit - budget.overheadBytes(partCount: parts.count) - settledBytes
        let narrowestFirst = cuttable.sorted {
            (budget.partBytes(columns[$0].targetKind) ?? 0) < (budget.partBytes(columns[$1].targetKind) ?? 0)
        }
        for (offset, part) in narrowestFirst.enumerated() {
            let share = remaining / (narrowestFirst.count - offset)
            let kind = columns[part].targetKind
            if let partBytes = budget.partBytes(kind), partBytes > share {
                let length = budget.length(of: kind, within: share)
                guard length > 0 else { return }
                cut(&columns[part], to: budget.spelling(for: kind, length: length), limit: limit)
            }
            remaining -= budget.partBytes(columns[part].targetKind) ?? 0
        }
    }

    private static func makeVariableLength(
        _ columns: inout [CrossEngineColumnDraft],
        parts: [Int],
        limit: Int,
        budget: CrossEngineKeyBudget
    ) {
        while let bytes = budget.checkedBytes(parts.map { columns[$0].targetKind }), bytes > limit {
            let fixed = parts.filter { part in
                let kind = columns[part].targetKind
                return budget.length(of: kind) != nil && !budget.isVariableLength(kind)
            }
            guard let widest = widestPart(fixed, in: columns, budget: budget),
                  let length = budget.length(of: columns[widest].targetKind) else { return }
            cut(&columns[widest], to: budget.spelling(for: columns[widest].targetKind, length: length), limit: limit)
        }
    }

    private static func widestPart(
        _ parts: [Int],
        in columns: [CrossEngineColumnDraft],
        budget: CrossEngineKeyBudget
    ) -> Int? {
        parts.max { (budget.partBytes(columns[$0].targetKind) ?? 0) < (budget.partBytes(columns[$1].targetKind) ?? 0) }
    }

    private static func cut(_ column: inout CrossEngineColumnDraft, to spelling: String, limit: Int) {
        column.respell(spelling, fidelity: .approximated, reason: String(
            format: String(
                localized: "At their declared lengths the key's columns pass the %1$@ bytes this engine can index, so this one is %2$@."
            ),
            limit.formatted(), spelling
        ))
    }

    // MARK: - Indexes

    /// The key prefixes a MySQL index needs, or nil when no prefix brings it under 3,072 bytes.
    ///
    /// An unbounded part takes a 255 prefix, which MySQL needs before it indexes one at all. Then,
    /// while the key is too wide, the widest part still longer than 255 is cut to 255. Cutting the
    /// widest first leaves the other parts whole, and a whole part is a stronger index.
    internal static func mysqlPrefixes(
        columns: [String],
        declared: [String: Int],
        kinds: [String: CanonicalTypeKind]
    ) -> [String: Int]? {
        var prefixes = declared
        for column in columns where isUnbounded(kinds[column.lowercased()]) {
            prefixes[column] = min(prefixes[column] ?? prefixLength, prefixLength)
        }

        func width(_ column: String) -> Int {
            guard let kind = kinds[column.lowercased()] else { return 0 }
            return MySQLStorageWidth.keyBytes(kind, prefix: prefixes[column]) ?? 0
        }

        while columns.reduce(0, { $0 + width($1) }) > MySQLStorageWidth.maximumKeyBytes {
            let cuttable = columns.filter { column in
                guard let kind = kinds[column.lowercased()] else { return false }
                return isCuttable(kind, prefix: prefixes[column])
            }
            guard let widest = cuttable.max(by: { width($0) < width($1) }) else { return nil }
            prefixes[widest] = prefixLength
        }
        return prefixes
    }

    // MARK: - Kinds

    /// A kind no engine with size-limited index entries can take in a key without a bound or a
    /// prefix.
    internal static func isUnbounded(_ kind: CanonicalTypeKind?) -> Bool {
        switch kind {
        case .text(let length, _), .binary(let length, _): return length == nil
        case .json, .xml, .spatial, .array: return true
        default: return false
        }
    }

    private static func isCuttable(_ kind: CanonicalTypeKind, prefix: Int?) -> Bool {
        switch kind {
        case .text(let length?, _), .binary(let length?, _):
            return min(length, prefix ?? length) > prefixLength
        default:
            return false
        }
    }
}
