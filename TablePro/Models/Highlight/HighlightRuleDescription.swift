//
//  HighlightRuleDescription.swift
//  TablePro
//

import Foundation

enum HighlightRuleDescription {
    static let menuValueLimit = 32

    static func condition(of rule: HighlightRule, valueLimit: Int? = nil) -> String {
        condition(
            columnName: rule.columnName,
            filterOperator: rule.filterOperator,
            value: rule.value,
            secondValue: rule.secondValue,
            valueLimit: valueLimit
        )
    }

    static func condition(
        columnName: String,
        filterOperator: FilterOperator,
        value: String,
        secondValue: String?,
        valueLimit: Int? = nil
    ) -> String {
        guard filterOperator.requiresValue else {
            return String(format: String(localized: "%1$@ %2$@"), columnName, filterOperator.displayName)
        }

        let first = truncated(value, to: valueLimit)
        if filterOperator.requiresSecondValue {
            return String(
                format: String(localized: "%1$@ between “%2$@” and “%3$@”"),
                columnName,
                first,
                truncated(secondValue ?? "", to: valueLimit)
            )
        }

        return String(
            format: String(localized: "%1$@ %2$@ “%3$@”"),
            columnName,
            operatorText(filterOperator),
            first
        )
    }

    /// A limited value is shown on one line, so its line breaks become spaces: `NSMenu` lays a
    /// title's line break out as nothing at all, which ran the two lines together.
    static func truncated(_ value: String, to limit: Int?) -> String {
        guard let limit, limit > 0 else { return value }
        let source = value as NSString
        guard source.length > limit else { return value.sanitizedForCellDisplay }
        let cut = source.rangeOfComposedCharacterSequence(at: limit).location
        return source.substring(to: cut).sanitizedForCellDisplay + "\u{2026}"
    }

    private static func operatorText(_ filterOperator: FilterOperator) -> String {
        switch filterOperator {
        case .equal, .notEqual, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual:
            return filterOperator.symbol
        case .contains, .notContains, .startsWith, .endsWith, .isNull, .isNotNull, .isEmpty,
             .isNotEmpty, .inList, .notInList, .between, .regex:
            return filterOperator.displayName
        }
    }
}
