//
//  UnloadedValuePlan.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// How an engine measures a value and reads the start of its text. Each template holds `{}` where the quoted
// column goes; a head's `{count}` counts characters, so a head never ends inside a UTF-8 sequence.
struct LargeValueFunctions: Equatable, Sendable {
    let binaryLength: String
    let textLength: String
    let textHead: String
    // Set where a document's text is built from its stored form on every read. Its stored size settles most cuts
    // without building that text: over the limit it is cut, within an eighth of the limit it is read whole, and only
    // one between is measured as text. A document compressed past an eighth of its text size is read whole. A cut
    // value's length and head still build its text.
    var documentStoredSize: String?
    // False where a declared size such as `varchar(255)` is not enforced, so it says nothing about how large a value is.
    var enforcesDeclaredLength = true
    // Types whose name carries their largest size, so a value of one under the limit is never cut.
    var boundedTypeBytes: [String: Int] = [:]

    static let mySQL = LargeValueFunctions(
        binaryLength: "OCTET_LENGTH({})", textLength: "OCTET_LENGTH({})", textHead: "LEFT({}, {count})",
        boundedTypeBytes: ["TINYTEXT": 255, "TINYBLOB": 255, "TEXT": 65_535, "BLOB": 65_535]
    )
    // `octet_length` takes no json, jsonb or xml, and `substr` reads a stored text only up to the slice it returns.
    // `pg_column_size` reads the stored size without decompressing or converting the value.
    static let postgreSQL = LargeValueFunctions(
        binaryLength: "octet_length({})", textLength: "octet_length({}::text)", textHead: "substr({}::text, 1, {count})",
        documentStoredSize: "pg_column_size({})"
    )
    // `length` counts a text's characters, its bytes only once cast.
    static let sqlite = LargeValueFunctions(
        binaryLength: "length(CAST({} AS BLOB))", textLength: "length(CAST({} AS BLOB))", textHead: "substr({}, 1, {count})",
        enforcesDeclaredLength: false
    )

    // The column goes in last, so text a quoted name holds is never read as a placeholder.
    static func render(_ template: String, column: String, count: Int? = nil) -> String {
        let counted = count.map { template.replacingOccurrences(of: "{count}", with: String($0)) } ?? template
        return counted.components(separatedBy: "{}").joined(separator: column)
    }
}

// A deferred column reads its value only up to the limit; its byte length, and for text its first characters,
// follow in trailing columns named after the column's position in the select list.
struct UnloadedValuePlan: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case binary
        case text
        // JSON, jsonb and XML: read as text, measured by their stored size where the engine offers one.
        case document

        var readsHead: Bool { self != .binary }
    }

    let columns: [String]
    let kinds: [String: Kind]
    let columnTypes: [String: ColumnType]
    let functions: LargeValueFunctions
    let inlineByteLimit: Int

    // MySQL's BLOB holds at most 64 KB, so a BLOB value always arrives with the page.
    static let defaultInlineByteLimit = 65_536
    // A grid line shows far fewer, and at four bytes a character the head stays near a kilobyte.
    static let headCharacterCount = 256
    static let lengthAliasPrefix = "__tablepro_byte_length_"
    static let headAliasPrefix = "__tablepro_head_"

    // A value is read back by key, and a sorted or value-filtered column needs its values in the page.
    static func resolve(
        selectedColumns: [String],
        columnTypes: [String: ColumnType],
        primaryKeys: [String],
        sortColumns: [String] = [],
        valueFilteredColumns: [String] = [],
        functions: LargeValueFunctions?,
        inlineByteLimit: Int
    ) -> UnloadedValuePlan? {
        guard let functions, !primaryKeys.isEmpty, primaryKeys.allSatisfy(selectedColumns.contains) else { return nil }
        let limit = max(0, inlineByteLimit)
        let kept = Set(primaryKeys).union(sortColumns).union(valueFilteredColumns)
        var deferred: [String] = []
        var kinds: [String: Kind] = [:]
        var types: [String: ColumnType] = [:]
        for name in selectedColumns where !kept.contains(name) && kinds[name] == nil {
            guard let type = columnTypes[name],
                  let kind = kind(
                      of: type, inlineByteLimit: limit,
                      trustsDeclaredLength: functions.enforcesDeclaredLength, boundedTypeBytes: functions.boundedTypeBytes
                  )
            else { continue }
            deferred.append(name)
            kinds[name] = kind
            types[name] = type
        }
        guard !deferred.isEmpty else { return nil }
        return UnloadedValuePlan(
            columns: deferred, kinds: kinds, columnTypes: types, functions: functions, inlineByteLimit: limit
        )
    }

    // A type whose declared size fits under the limit can never be cut, so it stays a plain column.
    static func kind(
        of type: ColumnType,
        inlineByteLimit: Int,
        trustsDeclaredLength: Bool = true,
        boundedTypeBytes: [String: Int] = [:]
    ) -> Kind? {
        let declared = trustsDeclaredLength ? declaredLength(type.rawType) : nil
        if let bound = boundedTypeBytes[baseTypeName(type.rawType)], bound <= inlineByteLimit { return nil }
        switch type {
        case .blob:
            if let declared, declared <= inlineByteLimit { return nil }
            return .binary
        case .json:
            return .document
        case .text(let rawType):
            let name = baseTypeName(rawType)
            if name == "XML" { return .document }
            guard characterTypeNames.contains(name) else { return nil }
            if let declared, declared.multipliedReportingOverflow(by: 4).partialValue <= inlineByteLimit { return nil }
            return .text
        default:
            return nil
        }
    }

    func selectList(for selectColumns: [String], quote: (String) -> String) -> String {
        var items: [String] = []
        var lengths: [String] = []
        var heads: [String] = []
        for (index, name) in selectColumns.enumerated() {
            let quoted = quote(name)
            guard let kind = kinds[name] else {
                items.append(quoted)
                continue
            }
            let template = kind == .binary ? functions.binaryLength : functions.textLength
            let length = LargeValueFunctions.render(template, column: quoted)
            let lengthAlias = quote(Self.lengthAliasPrefix + String(index))
            let isCut: String
            if kind == .document, let stored = functions.documentStoredSize {
                let storedSize = LargeValueFunctions.render(stored, column: quoted)
                isCut = """
                    (CASE WHEN \(storedSize) > \(inlineByteLimit) THEN TRUE \
                    WHEN \(storedSize) <= \(inlineByteLimit / 8) THEN FALSE \
                    ELSE \(length) > \(inlineByteLimit) END)
                    """
                items.append("CASE WHEN \(isCut) THEN NULL ELSE \(quoted) END AS \(quoted)")
                lengths.append("CASE WHEN \(isCut) THEN \(length) END AS \(lengthAlias)")
            } else {
                isCut = "\(length) > \(inlineByteLimit)"
                items.append("CASE WHEN \(length) <= \(inlineByteLimit) THEN \(quoted) END AS \(quoted)")
                lengths.append("\(length) AS \(lengthAlias)")
            }
            guard kind.readsHead else { continue }
            let head = LargeValueFunctions.render(functions.textHead, column: quoted, count: Self.headCharacterCount)
            heads.append("CASE WHEN \(isCut) THEN \(head) END AS \(quote(Self.headAliasPrefix + String(index)))")
        }
        return (items + lengths + heads).joined(separator: ", ")
    }

    func layout(for selectColumns: [String]) -> UnloadedValueLayout {
        UnloadedValueLayout(deferred: selectColumns.enumerated().compactMap { index, name in
            guard let kind = kinds[name] else { return nil }
            return UnloadedValueLayout.Deferred(position: index, type: columnTypes[name], readsHead: kind.readsHead)
        })
    }

    private static let characterTypeNames: Set<String> = [
        "TEXT", "TINYTEXT", "MEDIUMTEXT", "LONGTEXT", "CLOB", "NCLOB", "NTEXT", "CITEXT", "STRING",
        "VARCHAR", "CHARACTER VARYING", "NVARCHAR", "NATIONAL CHARACTER VARYING", "VARCHAR2", "NVARCHAR2",
        "CHAR", "CHARACTER", "NCHAR", "NATIONAL CHARACTER", "BPCHAR"
    ]

    private static func baseTypeName(_ rawType: String?) -> String {
        guard let rawType else { return "" }
        let name = rawType.prefix { $0 != "(" }.uppercased()
        return name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func declaredLength(_ rawType: String?) -> Int? {
        guard let rawType, let open = rawType.firstIndex(of: "("),
              let close = rawType[open...].firstIndex(of: ")") else { return nil }
        return Int(rawType[rawType.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
    }
}

// What a page built on a plan ends with: a length for each deferred column, then a head for each text one.
struct UnloadedValueLayout: Equatable, Sendable {
    struct Deferred: Equatable, Sendable {
        let position: Int
        // The table's own type, which an engine can lose through the CASE: SQLite reports no declared type for it.
        // It stands in only where the reported type is blank or of another kind, so a type the engine kept stays.
        let type: ColumnType?
        let readsHead: Bool
    }

    let deferred: [Deferred]

    var trailingColumns: [String] {
        deferred.map { UnloadedValuePlan.lengthAliasPrefix + String($0.position) }
            + deferred.filter(\.readsHead).map { UnloadedValuePlan.headAliasPrefix + String($0.position) }
    }
}

struct UnloadedValueFold {
    let columns: [String]
    let columnTypes: [ColumnType]
    let columnMeta: [ResultColumnMeta]?
    let unloadedCells: [Int: [Int: Int]]

    // Only the columns the page's plan asked for, so a table's own column of that name stays. The rows are cut
    // in place: each one already holds its trailing columns, so dropping them allocates nothing.
    static func fold(
        columns: [String],
        columnTypes: [ColumnType],
        rows: inout [[PluginCellValue]],
        columnMeta: [ResultColumnMeta]?,
        layout: UnloadedValueLayout?
    ) -> UnloadedValueFold? {
        guard let layout, !layout.deferred.isEmpty else { return nil }
        let trailing = layout.trailingColumns
        guard columns.count > trailing.count, Array(columns.suffix(trailing.count)) == trailing else { return nil }
        let start = columns.count - trailing.count
        guard layout.deferred.allSatisfy({ $0.position >= 0 && $0.position < start }) else { return nil }

        var headIndex: [Int: Int] = [:]
        var nextHead = start + layout.deferred.count
        for item in layout.deferred where item.readsHead {
            headIndex[item.position] = nextHead
            nextHead += 1
        }

        var unloaded: [Int: [Int: Int]] = [:]
        for rowIndex in rows.indices {
            let count = rows[rowIndex].count
            for (offset, item) in layout.deferred.enumerated() {
                let target = item.position
                let lengthIndex = start + offset
                guard lengthIndex < count, rows[rowIndex][target].isNull,
                      let length = byteLength(rows[rowIndex][lengthIndex]) else { continue }
                unloaded[rowIndex, default: [:]][target] = length
                // The head rides in the cell only to the grid's rows, which keep NULL there (`TableRows.liftingHeads`).
                if let index = headIndex[target], index < count, let head = headText(rows[rowIndex][index]) {
                    rows[rowIndex][target] = .text(head)
                }
            }
            if count > start { rows[rowIndex].removeLast(count - start) }
        }

        var types = Array(columnTypes.prefix(start))
        for item in layout.deferred where item.position < types.count {
            guard let type = item.type else { continue }
            let reported = types[item.position]
            if reported.displayName != type.displayName || (reported.rawType ?? "").isEmpty {
                types[item.position] = type
            }
        }
        return UnloadedValueFold(
            columns: Array(columns.prefix(start)),
            columnTypes: types,
            columnMeta: columnMeta.map { Array($0.prefix(start)) },
            unloadedCells: unloaded
        )
    }

    // An engine names no origin for a CASE expression, so a deferred column takes its table from the key's origin,
    // which is in every page a plan builds; a reader that masks by origin would otherwise hide the whole column.
    static func origins(
        _ origins: [PluginColumnOrigin?]?,
        columns: [String],
        layout: UnloadedValueLayout?
    ) -> [PluginColumnOrigin?]? {
        guard var kept = origins.map({ Array($0.prefix(columns.count)) }) else { return nil }
        guard let layout, let table = kept.lazy.compactMap({ $0 }).first else { return kept }
        for item in layout.deferred where kept.indices.contains(item.position) && kept[item.position] == nil {
            kept[item.position] = PluginColumnOrigin(schema: table.schema, table: table.table, column: columns[item.position])
        }
        return kept
    }

    private static func byteLength(_ cell: PluginCellValue) -> Int? {
        switch cell {
        case .null: return nil
        case .text(let text): return Int(text)
        case .bytes(let data): return String(bytes: data, encoding: .utf8).flatMap { Int($0) }
        }
    }

    // A head an engine hands back as bytes is shown only when it reads as text.
    private static func headText(_ cell: PluginCellValue) -> String? {
        switch cell {
        case .null: return nil
        case .text(let text): return text.isEmpty ? nil : text
        case .bytes(let data): return String(bytes: data, encoding: .utf8).flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}

extension QueryResult {
    mutating func foldUnloadedValues(_ layout: UnloadedValueLayout?) {
        var cut = rows
        rows = []
        guard let fold = UnloadedValueFold.fold(
            columns: columns, columnTypes: columnTypes, rows: &cut, columnMeta: columnMeta, layout: layout
        ) else {
            rows = cut
            return
        }
        var folded = QueryResult(
            columns: fold.columns,
            columnTypes: fold.columnTypes,
            rows: cut,
            rowsAffected: rowsAffected,
            executionTime: executionTime,
            error: error,
            timing: timing,
            isTruncated: isTruncated,
            statusMessage: statusMessage,
            columnMeta: fold.columnMeta,
            rowLocators: rowLocators,
            serverOutput: serverOutput,
            exportDocuments: exportDocuments,
            absentCells: absentCells
        )
        folded.unloadedCells = fold.unloadedCells
        // The fold drops the trailing columns, so the origins of the columns it keeps still line up.
        folded.columnOrigins = UnloadedValueFold.origins(columnOrigins, columns: fold.columns, layout: layout)
        self = folded
    }
}

extension QueryFetchResult {
    mutating func foldUnloadedValues(_ layout: UnloadedValueLayout?) {
        var cut = rows
        rows = []
        guard let fold = UnloadedValueFold.fold(
            columns: columns, columnTypes: columnTypes, rows: &cut, columnMeta: resultColumnMeta, layout: layout
        ) else {
            rows = cut
            return
        }
        var folded = QueryFetchResult(
            columns: fold.columns,
            columnTypes: fold.columnTypes,
            rows: cut,
            executionTime: executionTime,
            rowsAffected: rowsAffected,
            statusMessage: statusMessage,
            isTruncated: isTruncated,
            resultColumnMeta: fold.columnMeta,
            timing: timing,
            serverOutput: serverOutput,
            rowLocators: rowLocators,
            exportDocuments: exportDocuments,
            absentCells: absentCells
        )
        folded.unloadedCells = fold.unloadedCells
        // The fold drops the trailing columns, so the origins of the columns it keeps still line up.
        folded.columnOrigins = UnloadedValueFold.origins(columnOrigins, columns: fold.columns, layout: layout)
        self = folded
    }
}
