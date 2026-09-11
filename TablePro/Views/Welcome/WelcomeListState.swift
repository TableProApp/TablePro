//
//  WelcomeListState.swift
//  TablePro
//

import Foundation

internal enum WelcomeListState: Equatable {
    case firstRun
    case noSearchMatch(String)
    case noFilterMatch
    case content

    internal struct Input {
        internal let hasAnyConnection: Bool
        internal let hasVisibleContent: Bool
        internal let searchText: String
        internal let isTagFiltered: Bool

        internal init(hasAnyConnection: Bool, hasVisibleContent: Bool, searchText: String, isTagFiltered: Bool) {
            self.hasAnyConnection = hasAnyConnection
            self.hasVisibleContent = hasVisibleContent
            self.searchText = searchText
            self.isTagFiltered = isTagFiltered
        }
    }

    internal static func resolve(_ input: Input) -> WelcomeListState {
        if input.hasVisibleContent { return .content }
        if !input.hasAnyConnection { return .firstRun }
        if !input.searchText.isEmpty { return .noSearchMatch(input.searchText) }
        if input.isTagFiltered { return .noFilterMatch }
        return .content
    }
}
