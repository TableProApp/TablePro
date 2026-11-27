//
//  WelcomeListState.swift
//  TablePro
//

import Foundation

internal enum WelcomeListState: Equatable {
    case firstRun
    case emptyProject(String)
    case noSearchMatch(String)
    case noProjectSearchMatch(String, project: String)
    case noFilterMatch
    case content

    internal struct Input {
        internal let hasAnyConnection: Bool
        internal let hasVisibleContent: Bool
        internal let searchText: String
        internal let isTagFiltered: Bool
        // Nil in All Connections.
        internal let activeProjectName: String?

        internal init(
            hasAnyConnection: Bool,
            hasVisibleContent: Bool,
            searchText: String,
            isTagFiltered: Bool,
            activeProjectName: String? = nil
        ) {
            self.hasAnyConnection = hasAnyConnection
            self.hasVisibleContent = hasVisibleContent
            self.searchText = searchText
            self.isTagFiltered = isTagFiltered
            self.activeProjectName = activeProjectName
        }
    }

    internal static func resolve(_ input: Input) -> WelcomeListState {
        if input.hasVisibleContent { return .content }
        guard let project = input.activeProjectName else {
            if !input.hasAnyConnection { return .firstRun }
            if !input.searchText.isEmpty { return .noSearchMatch(input.searchText) }
            if input.isTagFiltered { return .noFilterMatch }
            return .content
        }
        // The first run offers the sample database, which lands in no project, so a project never shows it.
        if !input.searchText.isEmpty { return .noProjectSearchMatch(input.searchText, project: project) }
        if input.isTagFiltered { return .noFilterMatch }
        return .emptyProject(project)
    }
}
