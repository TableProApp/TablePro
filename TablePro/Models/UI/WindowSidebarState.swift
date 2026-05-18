//
//  WindowSidebarState.swift
//  TablePro
//

import Foundation
import Observation
import TableProPluginKit

@MainActor
@Observable
internal final class WindowSidebarState {
    var selectedTables: Set<TableInfo> = []
    var favoritesSearchText: String = ""
}
