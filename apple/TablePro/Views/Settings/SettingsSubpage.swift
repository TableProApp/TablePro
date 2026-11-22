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

    var parent: SettingsPane {
        switch self {
        case .softwareUpdate, .commandLine: .general
        }
    }

    var title: String {
        switch self {
        case .softwareUpdate: String(localized: "Software Update")
        case .commandLine: String(localized: "Command Line Tool")
        }
    }
}
