import Foundation

public extension PluginSQLFilter {
    static func buildWhereClause(
        filters: [PluginQueryFilter],
        logicMode: String,
        columnKinds: [String: PluginColumnKind],
        caseSensitivityStyle: SQLDialectDescriptor.CaseSensitivityStyle,
        caseFoldFunction: String = SQLDialectDescriptor.defaultCaseFoldFunction,
        quoteIdentifier: (String) -> String,
        escapeTypedValue: (_ value: String, _ kind: PluginColumnKind?) -> String,
        regexCondition: (_ quotedColumn: String, _ pattern: String, _ ignoresCase: Bool) -> String?
    ) -> String {
        let conditions = filters.compactMap { filter in
            buildFilterCondition(
                filter: filter,
                kind: columnKinds[filter.column],
                caseSensitivityStyle: caseSensitivityStyle,
                caseFoldFunction: caseFoldFunction,
                quoteIdentifier: quoteIdentifier,
                escapeTypedValue: escapeTypedValue,
                regexCondition: regexCondition
            )
        }
        guard !conditions.isEmpty else { return "" }
        let separator = logicMode == "and" ? " AND " : " OR "
        return conditions.joined(separator: separator)
    }

    static func buildFilterCondition(
        filter: PluginQueryFilter,
        kind: PluginColumnKind?,
        caseSensitivityStyle: SQLDialectDescriptor.CaseSensitivityStyle,
        caseFoldFunction: String = SQLDialectDescriptor.defaultCaseFoldFunction,
        quoteIdentifier: (String) -> String,
        escapeTypedValue: (_ value: String, _ kind: PluginColumnKind?) -> String,
        regexCondition: (_ quotedColumn: String, _ pattern: String, _ ignoresCase: Bool) -> String?
    ) -> String? {
        let folding = PluginSQLCaseFolding.resolve(
            style: caseSensitivityStyle,
            foldFunction: caseFoldFunction,
            isCaseSensitive: filter.isCaseSensitive
        )
        let quoted = quoteIdentifier(filter.column)
        let escape = { (value: String) in escapeTypedValue(value, kind) }

        switch filter.op {
        case "=", "!=":
            let negated = filter.op == "!="
            return comparisonCondition(
                quoted: quoted, value: filter.value, negated: negated, folding: folding,
                escapeValue: escape, regexCondition: regexCondition
            )
        case "CONTAINS", "NOT CONTAINS", "STARTS WITH", "ENDS WITH":
            return likeFamilyCondition(
                quoted: quoted, op: filter.op, value: filter.value, folding: folding,
                regexCondition: regexCondition
            )
        case "IN", "NOT IN":
            return listCondition(
                quoted: quoted, op: filter.op, value: filter.value, folding: folding, escapeValue: escape
            )
        case "REGEX":
            return regexCondition(quoted, filter.value, !filter.isCaseSensitive)
        default:
            return buildFilterCondition(
                column: filter.column,
                op: filter.op,
                value: filter.value,
                kind: kind,
                quoteIdentifier: quoteIdentifier,
                escapeTypedValue: escapeTypedValue,
                regexCondition: { column, value in regexCondition(column, value, false) }
            )
        }
    }

    private static func comparisonCondition(
        quoted: String,
        value: String,
        negated: Bool,
        folding: PluginSQLCaseFolding,
        escapeValue: (String) -> String,
        regexCondition: (String, String, Bool) -> String?
    ) -> String? {
        if folding.usesRegexForLike {
            let pattern = PluginSQLRegexPattern.pattern(
                matchingLiteral: value, anchoring: .exact, ignoresCase: false
            )
            guard let condition = regexCondition(quoted, pattern, true) else { return nil }
            return negated ? "NOT (\(condition))" : condition
        }
        let operatorText = negated ? "!=" : "="
        return "\(folding.foldingComparison(quoted)) \(operatorText) \(folding.foldingComparison(escapeValue(value)))"
    }

    private static func likeFamilyCondition(
        quoted: String,
        op: String,
        value: String,
        folding: PluginSQLCaseFolding,
        regexCondition: (String, String, Bool) -> String?
    ) -> String? {
        if folding.usesRegexForLike {
            guard let condition = regexCondition(quoted, regexPattern(op: op, value: value), true) else { return nil }
            return op == "NOT CONTAINS" ? "NOT (\(condition))" : condition
        }
        let keyword = op == "NOT CONTAINS" ? folding.notLikeKeyword : folding.likeKeyword
        let pattern = "'\(likePattern(op: op, value: value))'"
        let column = folding.foldingLikeOperand(quoted)
        return "\(column) \(keyword) \(folding.foldingLikeOperand(pattern)) ESCAPE '\\'"
    }

    private static func listCondition(
        quoted: String,
        op: String,
        value: String,
        folding: PluginSQLCaseFolding,
        escapeValue: (String) -> String
    ) -> String? {
        let values = value.split(separator: ",")
            .map { folding.foldingComparison(escapeValue($0.trimmingCharacters(in: .whitespaces))) }
            .joined(separator: ", ")
        guard !values.isEmpty else { return nil }
        let keyword = op == "NOT IN" ? "NOT IN" : "IN"
        return "\(folding.foldingComparison(quoted)) \(keyword) (\(values))"
    }

    private static func likePattern(op: String, value: String) -> String {
        let escaped = escapeForLike(value)
        switch op {
        case "STARTS WITH": return "\(escaped)%"
        case "ENDS WITH": return "%\(escaped)"
        default: return "%\(escaped)%"
        }
    }

    private static func regexPattern(op: String, value: String) -> String {
        let anchoring: PluginSQLRegexPattern.Anchoring
        switch op {
        case "STARTS WITH": anchoring = .prefix
        case "ENDS WITH": anchoring = .suffix
        default: anchoring = .unanchored
        }
        return PluginSQLRegexPattern.pattern(matchingLiteral: value, anchoring: anchoring, ignoresCase: false)
    }
}
