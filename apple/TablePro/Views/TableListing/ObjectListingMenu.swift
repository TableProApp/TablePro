//
//  ObjectListingMenu.swift
//  TablePro
//

import Foundation

/// What a row or the tool strip of the Objects tab does, routed to the coordinator commands the
/// sidebar's rows and the menu bar run.
internal enum ObjectListingAction: Equatable {
    case open(ObjectListingItem)
    case openInNewTab(ObjectListingItem)
    case showStructure(ObjectListingItem)
    case showSource(ObjectListingItem)
    case copyNames([String])
    case createTable
    case importData
    case export([ObjectListingItem])
    case drop([ObjectListingItem])
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

/// What the coordinator knows about the connection that the tool strip's buttons depend on.
internal struct ObjectListingCommandFacts: Equatable {
    /// Safe mode blocks every write.
    var isReadOnly = true
    var canCreateTable = false
    /// The connection imports at least one format.
    var canImport = false
    /// The engine has a drop statement for every selected object.
    var canDropSelection = false
}

/// Which of the tool strip's buttons apply to the selection, the kind and the connection.
internal struct ObjectListingCommandAvailability: Equatable {
    var canOpen = false
    var canDesign = false
    var canCreate = false
    var canDelete = false
    var canImport = false
    var canExport = false

    internal static let none = ObjectListingCommandAvailability()

    /// Open and Design act on one object, as a double click does. Delete and Export act on tables and
    /// other relations only: a routine or a type has its own drop path in the sidebar, and nothing exports one.
    internal static func resolve(
        kind: SidebarObjectKind,
        selection: [ObjectListingItem],
        facts: ObjectListingCommandFacts
    ) -> ObjectListingCommandAvailability {
        let relations = selection.filter { item in
            if case .relation = item { return true }
            return false
        }
        let selectsOnlyRelations = !selection.isEmpty && relations.count == selection.count
        return ObjectListingCommandAvailability(
            canOpen: selection.count == 1,
            canDesign: selection.count == 1 && selectsOnlyRelations,
            canCreate: kind == .table && facts.canCreateTable && !facts.isReadOnly,
            canDelete: selectsOnlyRelations && facts.canDropSelection && !facts.isReadOnly,
            canImport: kind == .table && facts.canImport && !facts.isReadOnly,
            canExport: selectsOnlyRelations
        )
    }
}
