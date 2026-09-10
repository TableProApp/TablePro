//
//  FilterCaseSensitivityPresentation.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// Resolves how a filter row presents its case setting, given the operator and what the engine can express.
struct FilterCaseSensitivityPresentation: Equatable {
    let showsControl: Bool
    let isAdjustable: Bool
    let showsIndicator: Bool
    let fixedReason: String?

    init(filterOperator: FilterOperator, isCaseSensitive: Bool, style: SQLDialectDescriptor.CaseSensitivityStyle) {
        let supportsCase = filterOperator.supportsCaseSensitivity
        let adjustable = PluginSQLCaseFolding.isAdjustable(style: style)
        self.showsControl = supportsCase
        self.isAdjustable = supportsCase && adjustable
        self.fixedReason = supportsCase && !adjustable ? Self.reason(for: style) : nil
        self.showsIndicator = supportsCase
            && adjustable
            && isCaseSensitive != filterOperator.defaultIsCaseSensitive
    }

    private static func reason(for style: SQLDialectDescriptor.CaseSensitivityStyle) -> String {
        switch style {
        case .collationDefined:
            return String(localized: "Set by the column's collation")
        default:
            return String(localized: "Not supported by this database")
        }
    }
}
