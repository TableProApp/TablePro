import Foundation
import TableProGoogleCloud
import TableProPluginKit

internal struct BigQueryQueryParams: Codable {
    let table: String
    let dataset: String
    let sortColumns: [SortColumn]?
    let limit: Int
    let offset: Int
    let filters: [BigQueryFilterSpec]?
    let logicMode: String?
    let searchText: String?
    let searchColumns: [String]?
    let columns: [String]?

    struct SortColumn: Codable {
        let columnIndex: Int
        let ascending: Bool
    }

    init(
        table: String,
        dataset: String,
        sortColumns: [SortColumn]?,
        limit: Int,
        offset: Int,
        filters: [BigQueryFilterSpec]?,
        logicMode: String?,
        searchText: String?,
        searchColumns: [String]?,
        columns: [String]? = nil
    ) {
        self.table = table
        self.dataset = dataset
        self.sortColumns = sortColumns
        self.limit = limit
        self.offset = offset
        self.filters = filters
        self.logicMode = logicMode
        self.searchText = searchText
        self.searchColumns = searchColumns
        self.columns = columns
    }

    func resolving(dataset resolvedDataset: String) -> BigQueryQueryParams {
        BigQueryQueryParams(
            table: table,
            dataset: resolvedDataset,
            sortColumns: sortColumns,
            limit: limit,
            offset: offset,
            filters: filters,
            logicMode: logicMode,
            searchText: searchText,
            searchColumns: searchColumns,
            columns: columns
        )
    }
}

internal struct BigQueryFilterSpec: Codable {
    let column: String
    let op: String
    let value: String
    var kind: String?
    var caseSensitive: Bool?
    var secondValue: String?

    var columnKind: PluginColumnKind? {
        guard let kind else { return nil }
        return PluginColumnKind(rawValue: kind)
    }

    var folding: PluginSQLCaseFolding {
        PluginSQLCaseFolding.resolve(
            style: .caseFoldFunction,
            isCaseSensitive: caseSensitive ?? true
        )
    }

    init(
        column: String,
        op: String,
        value: String,
        kind: String? = nil,
        caseSensitive: Bool? = nil,
        secondValue: String? = nil
    ) {
        self.column = column
        self.op = op
        self.value = value
        self.kind = kind
        self.caseSensitive = caseSensitive
        self.secondValue = secondValue
    }

    init(_ filter: PluginQueryFilter, kind: PluginColumnKind?) {
        self.init(
            column: filter.column,
            op: filter.op,
            value: filter.value,
            kind: kind?.rawValue,
            caseSensitive: filter.isCaseSensitive,
            secondValue: filter.secondValue
        )
    }
}

internal struct BigQueryQueryBuilder {
    static let browseTag = "BIGQUERY_BROWSE:"
    static let filterTag = "BIGQUERY_FILTER:"
    static let searchTag = "BIGQUERY_SEARCH:"
    static let combinedTag = "BIGQUERY_COMBINED:"
    static let rawFilterColumn = "__RAW__"

    private static let caseInsensitiveRegexFlag = "(?i)"

    static func encodeBrowseQuery(
        table: String,
        dataset: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int,
        columns: [String] = []
    ) -> String {
        let params = BigQueryQueryParams(
            table: table,
            dataset: dataset,
            sortColumns: sortColumns.map { .init(columnIndex: $0.columnIndex, ascending: $0.ascending) },
            limit: limit,
            offset: offset,
            filters: nil,
            logicMode: nil,
            searchText: nil,
            searchColumns: nil,
            columns: columns
        )
        return browseTag + encodeParams(params)
    }

    static func encodeFilteredQuery(
        table: String,
        dataset: String,
        filters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int,
        columns: [String] = [],
        columnKinds: [String: PluginColumnKind] = [:]
    ) -> String {
        let params = BigQueryQueryParams(
            table: table,
            dataset: dataset,
            sortColumns: sortColumns.map { .init(columnIndex: $0.columnIndex, ascending: $0.ascending) },
            limit: limit,
            offset: offset,
            filters: filters.map { BigQueryFilterSpec($0, kind: columnKinds[$0.column]) },
            logicMode: logicMode,
            searchText: nil,
            searchColumns: nil,
            columns: columns
        )
        return filterTag + encodeParams(params)
    }

    static func encodeSearchQuery(
        table: String,
        dataset: String,
        searchText: String,
        searchColumns: [String],
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int,
        columns: [String] = []
    ) -> String {
        let params = BigQueryQueryParams(
            table: table,
            dataset: dataset,
            sortColumns: sortColumns.map { .init(columnIndex: $0.columnIndex, ascending: $0.ascending) },
            limit: limit,
            offset: offset,
            filters: nil,
            logicMode: nil,
            searchText: searchText,
            searchColumns: searchColumns,
            columns: columns
        )
        return searchTag + encodeParams(params)
    }

    static func encodeCombinedQuery(
        table: String,
        dataset: String,
        filters: [PluginQueryFilter],
        logicMode: String,
        searchText: String,
        searchColumns: [String],
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int,
        columns: [String] = []
    ) -> String {
        let params = BigQueryQueryParams(
            table: table,
            dataset: dataset,
            sortColumns: sortColumns.map { .init(columnIndex: $0.columnIndex, ascending: $0.ascending) },
            limit: limit,
            offset: offset,
            filters: filters.map { BigQueryFilterSpec($0, kind: nil) },
            logicMode: logicMode,
            searchText: searchText,
            searchColumns: searchColumns,
            columns: columns
        )
        return combinedTag + encodeParams(params)
    }

    static func decode(_ query: String) -> BigQueryQueryParams? {
        for tag in [browseTag, filterTag, searchTag, combinedTag] where query.hasPrefix(tag) {
            return decodeParams(String(query.dropFirst(tag.count)))
        }
        return nil
    }

    static func isTaggedQuery(_ query: String) -> Bool {
        query.hasPrefix(browseTag)
            || query.hasPrefix(filterTag)
            || query.hasPrefix(searchTag)
            || query.hasPrefix(combinedTag)
    }

    static func qualifiedTable(projectId: String, dataset: String, table: String) -> String {
        [projectId, dataset, table].map(GoogleSQLLiteral.quotedIdentifier).joined(separator: ".")
    }

    static func buildSQL(from params: BigQueryQueryParams, projectId: String) -> String {
        let columns = params.columns ?? []
        let table = qualifiedTable(projectId: projectId, dataset: params.dataset, table: params.table)
        var sql = "SELECT * FROM \(table)"

        let whereClause = whereClause(for: params, columns: columns)
        if !whereClause.isEmpty {
            sql += " WHERE " + whereClause
        }

        let orderClauses = (params.sortColumns ?? []).compactMap { sort -> String? in
            guard columns.indices.contains(sort.columnIndex) else { return nil }
            let column = GoogleSQLLiteral.quotedIdentifier(columns[sort.columnIndex])
            return "\(column) \(sort.ascending ? "ASC" : "DESC")"
        }
        if !orderClauses.isEmpty {
            sql += " ORDER BY " + orderClauses.joined(separator: ", ")
        }

        sql += " LIMIT \(max(params.limit, 0)) OFFSET \(max(params.offset, 0))"
        return sql
    }

    static func buildCountSQL(from params: BigQueryQueryParams, projectId: String) -> String {
        let columns = params.columns ?? []
        let table = qualifiedTable(projectId: projectId, dataset: params.dataset, table: params.table)
        var sql = "SELECT COUNT(*) FROM \(table)"
        let whereClause = whereClause(for: params, columns: columns)
        if !whereClause.isEmpty {
            sql += " WHERE " + whereClause
        }
        return sql
    }

    static func countSQL(
        projectId: String,
        dataset: String,
        table: String,
        filters: [PluginQueryFilter],
        logicMode: String,
        columnKinds: [String: PluginColumnKind] = [:]
    ) -> String {
        let params = BigQueryQueryParams(
            table: table,
            dataset: dataset,
            sortColumns: nil,
            limit: 0,
            offset: 0,
            filters: filters.map { BigQueryFilterSpec($0, kind: columnKinds[$0.column]) },
            logicMode: logicMode,
            searchText: nil,
            searchColumns: nil
        )
        return buildCountSQL(from: params, projectId: projectId)
    }

    private static func whereClause(for params: BigQueryQueryParams, columns: [String]) -> String {
        var clauses: [String] = []

        let filterClauses = (params.filters ?? []).compactMap(filterClause)
        if !filterClauses.isEmpty {
            let logicMode = params.logicMode?.uppercased() == "OR" ? "OR" : "AND"
            clauses.append("(" + filterClauses.joined(separator: " \(logicMode) ") + ")")
        }

        if let searchText = params.searchText, !searchText.isEmpty {
            let searchColumns = params.searchColumns.flatMap { $0.isEmpty ? nil : $0 } ?? columns
            let pattern = containsPattern(searchText)
            let searchClauses = searchColumns.map { column in
                "\(textOperand(GoogleSQLLiteral.quotedIdentifier(column))) LIKE \(pattern)"
            }
            if !searchClauses.isEmpty {
                clauses.append("(" + searchClauses.joined(separator: " OR ") + ")")
            }
        }

        return clauses.joined(separator: " AND ")
    }

    private static func filterClause(_ filter: BigQueryFilterSpec) -> String? {
        if filter.column == rawFilterColumn {
            let raw = filter.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : "(\(raw))"
        }
        let column = GoogleSQLLiteral.quotedIdentifier(filter.column)
        let op = filter.op.uppercased()
        if let clause = patternClause(op, column: column, filter: filter) {
            return clause
        }
        return comparisonFilterClause(op, column: column, filter: filter)
    }

    private static func comparisonFilterClause(_ op: String, column: String, filter: BigQueryFilterSpec) -> String? {
        let kind = filter.columnKind
        let folding = filter.folding
        let isNullKeyword = filter.value.lowercased() == "null" && !PluginSQLLiteral.isKnownTextLike(kind)

        switch op {
        case "=":
            guard !isNullKeyword else { return "\(column) IS NULL" }
            return comparisonClause(column, "=", filter.value, kind: kind, folding: folding)
        case "!=", "<>":
            guard !isNullKeyword else { return "\(column) IS NOT NULL" }
            return comparisonClause(column, "!=", filter.value, kind: kind, folding: folding)
        case ">", ">=", "<", "<=":
            return "\(column) \(op) \(literal(filter.value, kind: kind))"
        case "IN", "NOT IN":
            return inClause(column, op: op, filter: filter, kind: kind, folding: folding)
        case "BETWEEN":
            return betweenClause(column, filter: filter, kind: kind)
        case "IS NULL":
            return "\(column) IS NULL"
        case "IS NOT NULL":
            return "\(column) IS NOT NULL"
        case "IS EMPTY":
            guard PluginSQLLiteral.supportsEmptyStringComparison(kind) else { return "\(column) IS NULL" }
            return "(\(column) IS NULL OR \(textOperand(column)) = '')"
        case "IS NOT EMPTY":
            guard PluginSQLLiteral.supportsEmptyStringComparison(kind) else { return "\(column) IS NOT NULL" }
            return "(\(column) IS NOT NULL AND \(textOperand(column)) != '')"
        default:
            return nil
        }
    }

    private static func patternClause(_ op: String, column: String, filter: BigQueryFilterSpec) -> String? {
        let folding = filter.folding
        let patternBody = GoogleSQLLiteral.likePatternBody(filter.value)
        switch op {
        case "LIKE", "NOT LIKE":
            let keyword = op == "LIKE" ? folding.likeKeyword : folding.notLikeKeyword
            let pattern = GoogleSQLLiteral.quotedString(filter.value)
            return likeClause(column, keyword: keyword, pattern: pattern, folding: folding)
        case "CONTAINS", "NOT CONTAINS":
            let keyword = op == "CONTAINS" ? folding.likeKeyword : folding.notLikeKeyword
            let pattern = containsPattern(filter.value)
            return likeClause(textOperand(column), keyword: keyword, pattern: pattern, folding: folding)
        case "STARTS WITH":
            let pattern = GoogleSQLLiteral.quotedString(patternBody + "%")
            return likeClause(textOperand(column), keyword: folding.likeKeyword, pattern: pattern, folding: folding)
        case "ENDS WITH":
            let pattern = GoogleSQLLiteral.quotedString("%" + patternBody)
            return likeClause(textOperand(column), keyword: folding.likeKeyword, pattern: pattern, folding: folding)
        case "REGEX":
            let flag = filter.caseSensitive == false ? caseInsensitiveRegexFlag : ""
            let pattern = GoogleSQLLiteral.quotedString(flag + filter.value)
            return "REGEXP_CONTAINS(\(textOperand(column)), \(pattern))"
        default:
            return nil
        }
    }

    private static func textOperand(_ column: String) -> String {
        "CAST(\(column) AS STRING)"
    }

    private static func containsPattern(_ value: String) -> String {
        GoogleSQLLiteral.quotedString("%" + GoogleSQLLiteral.likePatternBody(value) + "%")
    }

    private static func likeClause(
        _ operand: String,
        keyword: String,
        pattern: String,
        folding: PluginSQLCaseFolding
    ) -> String {
        "\(folding.foldingLikeOperand(operand)) \(keyword) \(folding.foldingLikeOperand(pattern))"
    }

    private static func inClause(
        _ column: String,
        op: String,
        filter: BigQueryFilterSpec,
        kind: PluginColumnKind?,
        folding: PluginSQLCaseFolding
    ) -> String? {
        let values = filter.value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        let literals = values.map { foldedLiteral(literal($0, kind: kind), folding: folding) }
        let operand = literals.contains(where: { $0.hasPrefix(folding.foldFunction) }) ? folding.fold(column) : column
        return "\(operand) \(op) (\(literals.joined(separator: ", ")))"
    }

    private static func betweenClause(
        _ column: String,
        filter: BigQueryFilterSpec,
        kind: PluginColumnKind?
    ) -> String? {
        let bounds: (lower: String, upper: String)
        if let secondValue = filter.secondValue {
            bounds = (filter.value, secondValue)
        } else {
            let parts = filter.value.split(separator: ",", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            bounds = (parts[0], parts[1])
        }
        let lower = bounds.lower.trimmingCharacters(in: .whitespaces)
        let upper = bounds.upper.trimmingCharacters(in: .whitespaces)
        guard !lower.isEmpty, !upper.isEmpty else { return nil }
        return "\(column) BETWEEN \(literal(lower, kind: kind)) AND \(literal(upper, kind: kind))"
    }

    private static func comparisonClause(
        _ column: String,
        _ operatorText: String,
        _ value: String,
        kind: PluginColumnKind?,
        folding: PluginSQLCaseFolding
    ) -> String {
        let valueLiteral = literal(value, kind: kind)
        let foldedValue = foldedLiteral(valueLiteral, folding: folding)
        guard foldedValue != valueLiteral else { return "\(column) \(operatorText) \(valueLiteral)" }
        return "\(folding.fold(column)) \(operatorText) \(foldedValue)"
    }

    private static func foldedLiteral(_ literal: String, folding: PluginSQLCaseFolding) -> String {
        guard folding.foldsComparisonOperands, literal.hasPrefix("'") else { return literal }
        return folding.fold(literal)
    }

    private static func literal(_ value: String, kind: PluginColumnKind?) -> String {
        guard kind != nil else { return untypedLiteral(value) }
        return PluginSQLLiteral.escapedLiteral(
            value,
            kind: kind,
            trueLiteral: "TRUE",
            falseLiteral: "FALSE",
            quote: GoogleSQLLiteral.quotedString
        )
    }

    private static func untypedLiteral(_ value: String) -> String {
        switch value.lowercased() {
        case "true":
            return "TRUE"
        case "false":
            return "FALSE"
        case "null":
            return "NULL"
        default:
            break
        }
        if PluginSQLLiteral.isIntegerLiteral(value) || isPlainDecimal(value) {
            return value
        }
        return GoogleSQLLiteral.quotedString(value)
    }

    private static func isPlainDecimal(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isASCIIDigitCharacter) else {
            return false
        }
        return PluginSQLLiteral.isIntegerLiteral(String(parts[0]))
    }

    private static func encodeParams(_ params: BigQueryQueryParams) -> String {
        guard let data = try? JSONEncoder().encode(params) else { return "" }
        return data.base64EncodedString()
    }

    private static func decodeParams(_ base64: String) -> BigQueryQueryParams? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(BigQueryQueryParams.self, from: data)
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool {
        isASCII && isWholeNumber
    }
}
