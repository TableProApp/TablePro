//
//  FilterCaseSensitivityPresentation.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum FilterCaseMatching: Equatable {
    case engine(SQLDialectDescriptor.CaseSensitivityStyle)
    case inMemory

    var isAdjustable: Bool {
        switch self {
        case .engine(let style):
            return PluginSQLCaseFolding.isAdjustable(style: style)
        case .inMemory:
            return true
        }
    }

    var fixedReason: String? {
        guard case .engine(let style) = self, !isAdjustable else { return nil }
        switch style {
        case .collationDefined:
            return String(localized: "Set by the column's collation")
        default:
            return String(localized: "Not supported by this database")
        }
    }
}

/// Resolves how a filter row presents its case setting, given the operator and what the engine can express.
struct FilterCaseSensitivityPresentation: Equatable {
    let showsControl: Bool
    let isAdjustable: Bool
    let showsIndicator: Bool
    let fixedReason: String?

    init(filterOperator: FilterOperator, isCaseSensitive: Bool, matching: FilterCaseMatching) {
        let supportsCase = filterOperator.supportsCaseSensitivity
        let adjustable = matching.isAdjustable
        self.showsControl = supportsCase
        self.isAdjustable = supportsCase && adjustable
        self.fixedReason = supportsCase ? matching.fixedReason : nil
        self.showsIndicator = supportsCase
            && adjustable
            && isCaseSensitive != filterOperator.defaultIsCaseSensitive
    }
}
