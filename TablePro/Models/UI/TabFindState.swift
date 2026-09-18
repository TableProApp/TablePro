//
//  TabFindState.swift
//  TablePro
//

import Foundation

struct FindMatch: Equatable, Hashable {
    let displayRow: Int
    let columnIndex: Int
}

enum FindScope: Equatable {
    case allRowsLoaded
    case pageOfMore
}

struct TabFindState: Equatable {
    var term: String
    var isVisible: Bool
    var matches: [FindMatch]
    var currentMatchIndex: Int?
    var scope: FindScope

    init(isVisible: Bool = false) {
        term = ""
        self.isVisible = isVisible
        matches = []
        currentMatchIndex = nil
        scope = .allRowsLoaded
    }

    var currentMatch: FindMatch? {
        guard let index = currentMatchIndex, index >= 0, index < matches.count else { return nil }
        return matches[index]
    }

    var canEscalateToAllRows: Bool {
        scope == .pageOfMore && !term.isEmpty
    }

    mutating func clearMatches() {
        matches = []
        currentMatchIndex = nil
    }

    mutating func stepForward() {
        guard !matches.isEmpty else { return }
        guard let index = currentMatchIndex else {
            currentMatchIndex = 0
            return
        }
        currentMatchIndex = (index + 1) % matches.count
    }

    mutating func stepBackward() {
        guard !matches.isEmpty else { return }
        guard let index = currentMatchIndex else {
            currentMatchIndex = matches.count - 1
            return
        }
        currentMatchIndex = (index - 1 + matches.count) % matches.count
    }
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
