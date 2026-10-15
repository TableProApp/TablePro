import Foundation

/// `ReadRows` bodies. A nil body means the filters admit no row, which is not something a request
/// can say: an empty row set reads the whole table.
public enum BigtableReadRequest {
    public static let rawFilterColumn = BigtableRowFilter.rawColumn

    /// `after` continues a page past that key. `keysOnly` reads one stripped cell per row, which is
    /// how a page with no cursor yet skips the rows before it and how a count reads every key.
    public static func body(spec: BigtableBrowseSpec, limit: Int, after: Data?, keysOnly: Bool = false) throws -> [String: Any]? {
        if (spec.sortColumn.map { $0 != BigtableRowSet.keyColumn } ?? false) || spec.descending {
            throw BigtableError.unsupported(String(localized: "The Bigtable REST API returns rows in ascending key order only."))
        }
        var selection: [BigtableKeyBounds]
        var rowFilters: [[String: Any]] = []
        let keyRanges = spec.filters.filter(isKeyRange)
        if spec.usesOr, !keyRanges.isEmpty, keyRanges.count == spec.filters.count {
            selection = try keyRanges.map { filter in
                var bounds = BigtableKeyBounds()
                try apply(filter, to: &bounds)
                return bounds
            }
        } else {
            var bounds = BigtableKeyBounds()
            for filter in spec.filters {
                if !spec.usesOr, isKeyRange(filter) {
                    try apply(filter, to: &bounds)
                } else {
                    rowFilters.append(try BigtableRowFilter.make(filter, insideOr: spec.usesOr))
                }
            }
            selection = [bounds]
        }
        if let after {
            for index in selection.indices {
                selection[index].raiseStart(after, closed: false)
            }
        }
        guard let rows = rowSet(selection) else { return nil }

        var body: [String: Any] = [:]
        if !rows.isEmpty { body["rows"] = rows }
        var filters: [[String: Any]] = []
        switch rowFilters.count {
        case 0: break
        case 1: filters.append(rowFilters[0])
        default: filters.append([spec.usesOr ? "interleave" : "chain": ["filters": rowFilters]])
        }
        filters += keysOnly ? keysOnlyFilters : [["cellsPerColumnLimitFilter": 1]]
        body["filter"] = filters.count == 1 ? filters[0] : ["chain": ["filters": filters]]
        if limit > 0 { body["rowsLimit"] = String(limit) }
        return body
    }

    /// The first rows of a table with their values stripped, which is enough to learn its columns.
    public static func columnSample(limit: Int) -> [String: Any] {
        [
            "rowsLimit": String(limit),
            "filter": ["chain": ["filters": [["cellsPerColumnLimitFilter": 1], ["stripValueTransformer": true]]]]
        ]
    }

    public static func keyLookup(_ key: Data) -> [String: Any] {
        [
            "rows": ["rowKeys": [key.base64EncodedString()]],
            "rowsLimit": "1",
            "filter": ["chain": ["filters": keysOnlyFilters]]
        ]
    }

    public static func get(_ key: Data) -> [String: Any] {
        ["rows": ["rowKeys": [key.base64EncodedString()]], "filter": ["cellsPerColumnLimitFilter": 1]]
    }

    private static var keysOnlyFilters: [[String: Any]] {
        [["cellsPerRowLimitFilter": 1], ["stripValueTransformer": true]]
    }

    /// The union of `selection` as a `RowSet`: empty for the whole table, nil for no row at all.
    private static func rowSet(_ selection: [BigtableKeyBounds]) -> [String: Any]? {
        let live = selection.filter { !$0.isEmpty }
        guard !live.isEmpty else { return nil }
        if live.contains(where: \.isUnbounded) { return [:] }
        var keys: [String] = []
        var ranges: [[String: Any]] = []
        for bounds in live {
            if bounds.exact != nil {
                for key in bounds.admittedKeys.map({ $0.base64EncodedString() }) where !keys.contains(key) {
                    keys.append(key)
                }
            } else {
                ranges.append(bounds.rangeJSON)
            }
        }
        var rows: [String: Any] = [:]
        if !keys.isEmpty { rows["rowKeys"] = keys }
        if !ranges.isEmpty { rows["rowRanges"] = ranges }
        return rows
    }

    /// A key test a row range can express. A case-insensitive equality or prefix cannot, so it runs
    /// as a key regex instead.
    static func isKeyRange(_ filter: BigtableFilterSpec) -> Bool {
        guard filter.column == BigtableRowSet.keyColumn else { return false }
        switch filter.op {
        case ">", ">=", "<", "<=", "BETWEEN": return true
        case "=", "IN", "STARTS WITH": return filter.isCaseSensitive
        default: return false
        }
    }

    static func apply(_ filter: BigtableFilterSpec, to bounds: inout BigtableKeyBounds) throws {
        switch filter.op {
        case "=":
            bounds.restrict(to: [try BigtableBytes.parse(filter.value)])
        case "IN":
            bounds.restrict(to: try BigtableRowFilter.listItems(filter.value).map(BigtableBytes.parse))
        case "STARTS WITH":
            let prefix = try BigtableBytes.parse(filter.value)
            bounds.raiseStart(prefix, closed: true)
            if let end = BigtableBytes.prefixEnd(prefix) { bounds.lowerEnd(end, closed: false) }
        case ">": bounds.raiseStart(try BigtableBytes.parse(filter.value), closed: false)
        case ">=": bounds.raiseStart(try BigtableBytes.parse(filter.value), closed: true)
        case "<": bounds.lowerEnd(try BigtableBytes.parse(filter.value), closed: false)
        case "<=": bounds.lowerEnd(try BigtableBytes.parse(filter.value), closed: true)
        case "BETWEEN":
            guard let upper = filter.secondValue else {
                throw BigtableError.configuration(String(localized: "BETWEEN needs two values."))
            }
            bounds.raiseStart(try BigtableBytes.parse(filter.value), closed: true)
            bounds.lowerEnd(try BigtableBytes.parse(upper), closed: true)
        default:
            throw BigtableError.unsupported(BigtableRowFilter.unsupportedMessage(filter.op))
        }
    }
}
