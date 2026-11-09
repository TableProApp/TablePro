//
//  ObjectListingMenu.swift
//  TablePro
//

import Foundation

/// What a row of the Objects tab does, routed to the coordinator commands the sidebar's rows run.
internal enum ObjectListingAction: Equatable {
    case open(ObjectListingItem)
    case openInNewTab(ObjectListingItem)
    case showStructure(ObjectListingItem)
    case showSource(ObjectListingItem)
    case copyNames([String])
}

internal struct ObjectListingMenuCommand: Equatable {
    let title: String
    let action: ObjectListingAction
}

/// A row's commands as values, in the words the sidebar uses for the same object.
internal enum ObjectListingMenu {
    internal static func primaryAction(for item: ObjectListingItem) -> ObjectListingAction {
        switch item {
        case .relation: return .open(item)
        case .sourced: return .showSource(item)
        }
    }

    /// The clicked row's own commands, then Copy Name over every row the menu acts on.
    internal static func commands(clicked: ObjectListingItem, targets: [ObjectListingItem]) -> [ObjectListingMenuCommand] {
        var commands: [ObjectListingMenuCommand] = []
        if case .relation = clicked {
            commands.append(ObjectListingMenuCommand(title: String(localized: "Open in New Tab"), action: .openInNewTab(clicked)))
            commands.append(ObjectListingMenuCommand(title: String(localized: "Show Structure"), action: .showStructure(clicked)))
        }
        if let title = sourceTitle(for: clicked) {
            commands.append(ObjectListingMenuCommand(title: title, action: .showSource(clicked)))
        }
        let names = (targets.isEmpty ? [clicked] : targets).map(\.name)
        commands.append(ObjectListingMenuCommand(title: copyNamesTitle(count: names.count), action: .copyNames(names)))
        return commands
    }

    // The source viewer reads views, routines, triggers and types; a table's definition is on its Structure tab.
    private static func sourceTitle(for item: ObjectListingItem) -> String? {
        switch item {
        case .relation(_, _, let type):
            return DatabaseObjectKind(tableType: type) == nil ? nil : String(localized: "Show DDL")
        case .sourced(let ref):
            return ref.kind == .userType ? String(localized: "Show Definition") : String(localized: "Show DDL")
        }
    }

    private static func copyNamesTitle(count: Int) -> String {
        count == 1 ? String(localized: "Copy Name") : String(format: String(localized: "Copy %lld Names"), count)
    }
}
