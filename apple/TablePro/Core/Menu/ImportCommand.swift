//
//  ImportCommand.swift
//  TablePro
//

import AppKit

// One list for the File menu, the Welcome pull-down, the Welcome context menu and the setup guide.
enum ImportCommand: Int, CaseIterable, Sendable {
    case connectionsFile
    case url
    case otherApp
    case aws
    case projectFolder

    var title: String {
        switch self {
        case .connectionsFile: String(localized: "Import Connections…")
        case .url: String(localized: "Import from URL…")
        case .otherApp: String(localized: "Import from Other App…")
        case .aws: String(localized: "Import from AWS…")
        case .projectFolder: String(localized: "Open Project Folder…")
        }
    }

    // A separator goes before it: it reads a folder rather than importing a list.
    var startsGroup: Bool {
        self == .projectFolder
    }

    var menuAction: Selector {
        switch self {
        case .connectionsFile: #selector(AppDelegate.importConnections(_:))
        case .url: #selector(AppDelegate.importFromURL(_:))
        case .otherApp: #selector(AppDelegate.importFromOtherApp(_:))
        case .aws: #selector(AppDelegate.importFromAWS(_:))
        case .projectFolder: #selector(AppDelegate.openProjectFolder(_:))
        }
    }

    var welcomeRequest: WelcomeRequest {
        switch self {
        case .connectionsFile: .importConnections
        case .url: .importFromURL
        case .otherApp: .importFromApp
        case .aws: .importFromAWS
        case .projectFolder: .openProjectFolder
        }
    }

    // The commands between separators, in list order.
    static var groups: [[ImportCommand]] {
        allCases.reduce(into: [[ImportCommand]]()) { groups, command in
            if command.startsGroup || groups.isEmpty {
                groups.append([command])
            } else {
                groups[groups.count - 1].append(command)
            }
        }
    }
}
