//
//  HighlightRuleWarning.swift
//  TablePro
//

import Foundation

enum HighlightRuleWarning: Equatable {
    case columnMissing(String)
    case unusablePattern

    static func warning(for rule: HighlightRule, isColumnPresent: Bool) -> HighlightRuleWarning? {
        guard isColumnPresent else { return .columnMissing(rule.columnName) }
        return rule.hasUnusablePattern ? .unusablePattern : nil
    }

    var label: String {
        switch self {
        case .columnMissing:
            return String(localized: "Not in this result")
        case .unusablePattern:
            return String(localized: "Invalid pattern")
        }
    }

    var help: String {
        switch self {
        case .columnMissing(let columnName):
            return String(format: String(localized: "This result has no column named %@"), columnName)
        case .unusablePattern:
            return String(localized: "TablePro cannot use this pattern, so the rule matches nothing")
        }
    }
}
