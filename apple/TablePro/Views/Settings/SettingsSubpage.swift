//
//  SettingsSubpage.swift
//  TablePro
//

import Foundation

// A drill-in page pushed onto a pane's NavigationStack in the Settings detail column. Payload-free
// so it is Hashable for navigationDestination and can carry a deep-link id later. Leaf editors that
// need an id (a plugin, a profile) stay sheets for now.
enum SettingsSubpage: String, Hashable, CaseIterable {
    case softwareUpdate
    case commandLine
    case manageThemes
    case sqlFormatting
    case queryHistory
    case dataRewind
    case whatSyncs

    var parent: SettingsPane {
        switch self {
        case .softwareUpdate, .commandLine: .general
        case .manageThemes: .appearance
        case .sqlFormatting: .editor
        case .queryHistory, .dataRewind: .data
        case .whatSyncs: .sync
        }
    }

    var title: String {
        switch self {
        case .softwareUpdate: String(localized: "Software Update")
        case .commandLine: String(localized: "Command Line Tool")
        case .manageThemes: String(localized: "Manage Themes")
        case .sqlFormatting: String(localized: "SQL Formatting")
        case .queryHistory: String(localized: "Query History")
        case .dataRewind: String(localized: "Data Rewind")
        case .whatSyncs: String(localized: "What Syncs")
        }
    }
}
