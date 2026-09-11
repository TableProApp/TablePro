//
//  WelcomeContextMenuKind.swift
//  TablePro
//

import Foundation

internal enum WelcomeContextMenuKind: Equatable {
    case newConnection
    case singleConnection
    case multipleConnections
    case externalOnly

    internal static func resolve(savedCount: Int, externalCount: Int) -> WelcomeContextMenuKind {
        guard savedCount > 0 else {
            return externalCount > 0 ? .externalOnly : .newConnection
        }
        return savedCount + externalCount == 1 ? .singleConnection : .multipleConnections
    }
}

internal enum WelcomeSelectionLabels {
    static func connect(count: Int) -> String {
        count == 1
            ? String(localized: "Connect")
            : String(format: String(localized: "Connect %d Connections"), count)
    }

    static func exportToFile(count: Int) -> String {
        count == 1
            ? String(localized: "Export to File…")
            : String(format: String(localized: "Export %d Connections to File…"), count)
    }

    static func publishToTeamCatalog(count: Int) -> String {
        count == 1
            ? String(localized: "Publish to Team Catalog…")
            : String(format: String(localized: "Publish %d Connections to Team Catalog…"), count)
    }

    static func publishToTeamLibrary(count: Int) -> String {
        count == 1
            ? String(localized: "Publish to Team Library…")
            : String(format: String(localized: "Publish %d Connections to Team Library…"), count)
    }

    static func delete(count: Int) -> String {
        count == 1
            ? String(localized: "Delete")
            : String(format: String(localized: "Delete %d Connections"), count)
    }
}
