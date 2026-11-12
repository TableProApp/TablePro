//
//  ObjectListingKinds.swift
//  TablePro
//

import Foundation

/// Which kinds an Objects tab offers for its container: the groups the sidebar shows there.
internal enum ObjectListingKinds {
    /// Tables always, so a container holding nothing else still has a kind to show. Another kind is
    /// offered when the container holds some, as a sidebar group is, and a routine, trigger or type
    /// kind only where the engine fetches it. The tab's own kind stays while it is empty.
    internal static func available(
        itemCounts: [SidebarObjectKind: Int],
        declared: Set<SidebarObjectKind>,
        current: SidebarObjectKind
    ) -> [SidebarObjectKind] {
        SidebarObjectKind.builtIn.filter { kind in
            if kind == .table || kind == current { return true }
            if kind.category != .table, !declared.contains(kind) { return false }
            return itemCounts[kind, default: 0] > 0
        }
    }

    /// Relation kinds come from the table list every engine reads, so only a routine, trigger or
    /// type kind can stop being fetched after a reconnect; the tab then shows Tables.
    internal static func effective(_ kind: SidebarObjectKind, declared: Set<SidebarObjectKind>) -> SidebarObjectKind {
        kind.category == .table || declared.contains(kind) ? kind : .table
    }

    internal static func itemCounts(
        tables: [TableInfo],
        routines: [RoutineInfo],
        triggers: [TriggerInfo],
        types: [UserDefinedTypeInfo]
    ) -> [SidebarObjectKind: Int] {
        var counts: [SidebarObjectKind: Int] = [:]
        for table in tables {
            counts[SidebarObjectKind.resolve(tableType: table.type), default: 0] += 1
        }
        for routine in routines {
            counts[routine.kind.sidebarObjectKind, default: 0] += 1
        }
        counts[.trigger] = triggers.count
        counts[.type] = types.count
        return counts
    }
}

extension SidebarObjectKind {
    var listingFailureTitle: String {
        switch self {
        case .table: return String(localized: "Can't List Tables")
        case .view: return String(localized: "Can't List Views")
        case .materializedView: return String(localized: "Can't List Materialized Views")
        case .foreignTable: return String(localized: "Can't List Foreign Tables")
        case .sequence: return String(localized: "Can't List Sequences")
        case .procedure: return String(localized: "Can't List Procedures")
        case .function: return String(localized: "Can't List Functions")
        case .trigger: return String(localized: "Can't List Triggers")
        case .type: return String(localized: "Can't List Types")
        case .server(let kind): return String(format: String(localized: "Can't List %@"), kind.pluralDisplayName)
        }
    }

    var listingEmptyTitle: String {
        switch self {
        case .table: return String(localized: "No Tables")
        case .view: return String(localized: "No Views")
        case .materializedView: return String(localized: "No Materialized Views")
        case .foreignTable: return String(localized: "No Foreign Tables")
        case .sequence: return String(localized: "No Sequences")
        case .procedure: return String(localized: "No Procedures")
        case .function: return String(localized: "No Functions")
        case .trigger: return String(localized: "No Triggers")
        case .type: return String(localized: "No Types")
        case .server(let kind): return String(format: String(localized: "No %@"), kind.pluralDisplayName)
        }
    }
}
