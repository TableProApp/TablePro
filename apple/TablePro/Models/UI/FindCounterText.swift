//
//  FindCounterText.swift
//  TablePro
//

import Foundation

enum FindScope: Equatable {
    case allRowsLoaded
    case pageOfMore
}

enum FindCounterText {
    static func text(matchCount: Int, currentIndex: Int?, scope: FindScope) -> String {
        guard matchCount > 0 else { return emptyText(scope: scope) }

        let position = (currentIndex ?? 0) + 1
        switch scope {
        case .allRowsLoaded:
            return String(
                format: String(localized: "%1$@ of %2$@"),
                position.formatted(),
                matchCount.formatted()
            )
        case .pageOfMore:
            return String(
                format: String(localized: "%1$@ of %2$@ on this page"),
                position.formatted(),
                matchCount.formatted()
            )
        }
    }

    private static func emptyText(scope: FindScope) -> String {
        switch scope {
        case .allRowsLoaded: String(localized: "No matches")
        case .pageOfMore: String(localized: "Not on this page")
        }
    }
}
