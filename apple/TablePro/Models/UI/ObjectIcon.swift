//
//  ObjectIcon.swift
//  TablePro
//

import Foundation

/// What an object glyph stands for, on every surface that draws one: the sidebar, the editor tabs,
/// the Objects list, the quick switcher, the recent tab switcher and the toolbar's Objects buttons.
internal enum ObjectIconKind: Hashable, Sendable {
    case database
    case systemDatabase
    case schema
    case externalSchema
    case relation(TableInfo.TableType)
    case partition
    case routine(RoutineInfo.Kind)
    case trigger
    case userType(UserDefinedTypeInfo.Kind)
    /// The row or tab that lists one kind of object, such as the Tables section.
    case section(SidebarObjectKind)
    case tableFolder
    case query
    case savedQuery
    case user
    /// The sidebar sections that list tables by how the reader came to them rather than by kind.
    case recentSection
    case temporarySection
    case favoritesSection
    /// What an expanded table lists under it: its columns, its indexes and its constraints, and the
    /// group that holds each kind. A primary key's column and its index share one glyph.
    case column
    case primaryKey
    case index
    case foreignKey
    case checkConstraint
    case tableDetailGroup(TableDetailGroupKind)
    // A kind a driver declares, drawn with the symbol it names.
    case serverObject(String)

    /// The kind a section, an Objects tab or a menu of one kind of object stands for.
    internal init(_ kind: SidebarObjectKind) {
        switch kind {
        case .table: self = .relation(.table)
        case .view: self = .relation(.view)
        case .materializedView: self = .relation(.materializedView)
        case .foreignTable: self = .relation(.foreignTable)
        case .sequence: self = .relation(.sequence)
        case .procedure: self = .routine(.procedure)
        case .function: self = .routine(.function)
        case .trigger: self = .trigger
        case .type: self = .userType(.other)
        case .server(let kind): self = .serverObject(kind.iconName)
        }
    }

    internal init(_ ref: DatabaseObjectRef) {
        switch ref.kind {
        case .procedure: self = .routine(.procedure)
        case .function: self = .routine(.function)
        case .trigger: self = .trigger
        case .userType: self = .userType(ref.typeKind ?? .other)
        case .view: self = .relation(.view)
        case .materializedView: self = .relation(.materializedView)
        case .serverObject: self = .serverObject(ref.serverKind?.iconName ?? ref.kind.iconName)
        }
    }

    internal init(_ item: TableDetailItem) {
        switch item {
        case .column(let column): self = column.isPrimaryKey ? .primaryKey : .column
        case .index(let index): self = index.isPrimary ? .primaryKey : .index
        case .foreignKey: self = .foreignKey
        case .check: self = .checkConstraint
        }
    }

    /// The object a tab shows, or nil for a tool tab that shows none, such as the ER diagram.
    internal init?(tab: QueryTab) {
        switch tab.tabType {
        case .query:
            self = .query
        case .table:
            self = .relation(tab.tableContext.resolvedObjectKind())
        case .objectSource:
            guard let ref = tab.display.objectRef else { return nil }
            self = ObjectIconKind(ref)
        case .tableListing:
            self = .section(tab.display.listingKind ?? .table)
        case .usersRoles:
            self = .user
        case .createTable, .erDiagram, .serverDashboard, .insights, .tableHealth, .versionHistory,
             .routineDebug, .liveMessages:
            return nil
        }
    }
}

/// A system hue, so the glyph follows Light, Dark and Increase Contrast like the rest of the chrome.
internal enum ObjectIconTint: String, CaseIterable, Sendable {
    case gray
    case green
    case teal
    case blue
    case cyan
    case indigo
    case purple
    case orange
    case yellow
    case pink
    case mint
    case brown
}

internal struct ObjectIcon: Equatable, Sendable {
    internal let symbolName: String
    /// Nil in the standard style: the surface draws the glyph in the color it always used, which is
    /// the accent on a sidebar object and the label color on a database or schema row.
    internal let tint: ObjectIconTint?

    internal init(symbolName: String, tint: ObjectIconTint? = nil) {
        self.symbolName = symbolName
        self.tint = tint
    }
}

/// The one place that decides which glyph and which hue a kind of object wears in each style.
///
/// The standard style is the look from before the setting existed, glyph for glyph: a surface whose
/// glyph for a kind differed from the sidebar's passes it as `standard`, so turning the style back
/// off restores every surface exactly. The colorful set is original: SF Symbols with a fill where
/// one exists, each in its kind's system hue.
internal enum ObjectIconProvider {
    internal static func icon(
        for kind: ObjectIconKind,
        style: ObjectIconStyle,
        standard: String? = nil
    ) -> ObjectIcon {
        switch style {
        case .standard:
            return ObjectIcon(symbolName: standard ?? standardSymbolName(for: kind))
        case .colorful:
            return colorfulIcon(for: kind)
        }
    }

    /// The sidebar's glyph for the kind.
    internal static func standardSymbolName(for kind: ObjectIconKind) -> String {
        switch kind {
        case .database: return "cylinder"
        case .systemDatabase: return "gearshape"
        case .schema: return "folder"
        case .externalSchema: return "folder.badge.gearshape"
        case .relation(let type): return TableRowLogic.iconName(for: type)
        case .partition: return SidebarPartitionRow.iconName
        case .routine(let kind): return RoutineRowLogic.iconName(for: kind)
        case .trigger: return SidebarObjectKind.trigger.iconName
        case .userType(let kind): return kind.iconName
        case .section(let kind): return kind.iconName
        case .tableFolder: return "folder"
        case .query: return "doc.text"
        case .savedQuery: return "star"
        case .user: return "person.2"
        case .recentSection: return "clock"
        case .temporarySection: return "hourglass"
        case .favoritesSection: return "star"
        case .column: return "rectangle.portrait"
        case .primaryKey: return "key"
        case .index: return "list.bullet"
        case .foreignKey: return "link"
        case .checkConstraint: return "checkmark.shield"
        case .tableDetailGroup(.columns): return "tablecells"
        case .tableDetailGroup(let group): return standardSymbolName(for: Self.detailKind(of: group))
        case .serverObject(let symbolName): return symbolName
        }
    }

    internal static func colorfulIcon(for kind: ObjectIconKind) -> ObjectIcon {
        switch kind {
        case .database: return ObjectIcon(symbolName: "cylinder.split.1x2.fill", tint: .green)
        case .systemDatabase: return ObjectIcon(symbolName: "gearshape.fill", tint: .gray)
        case .schema: return ObjectIcon(symbolName: "square.stack.3d.up.fill", tint: .teal)
        case .externalSchema: return ObjectIcon(symbolName: "square.stack.3d.forward.dottedline.fill", tint: .teal)
        case .relation(let type): return colorfulRelation(type)
        case .partition: return ObjectIcon(symbolName: "rectangle.split.3x1.fill", tint: .blue)
        case .routine(.function): return ObjectIcon(symbolName: "function", tint: .purple)
        case .routine(.procedure): return ObjectIcon(symbolName: "curlybraces.square.fill", tint: .orange)
        case .trigger: return ObjectIcon(symbolName: "bolt.fill", tint: .yellow)
        // One glyph for every kind of type: the hue names the object, and the tooltip names its shape.
        case .userType: return ObjectIcon(symbolName: "t.square.fill", tint: .pink)
        case .section(let objectKind):
            return ObjectIcon(symbolName: "folder.fill", tint: colorfulIcon(for: ObjectIconKind(objectKind)).tint)
        case .tableFolder: return ObjectIcon(symbolName: "folder.fill", tint: .blue)
        case .query, .savedQuery: return ObjectIcon(symbolName: "doc.text.fill", tint: .orange)
        case .user: return ObjectIcon(symbolName: "person.fill", tint: .brown)
        case .recentSection: return ObjectIcon(symbolName: "clock.fill", tint: .indigo)
        case .temporarySection: return ObjectIcon(symbolName: "hourglass.bottomhalf.filled", tint: .orange)
        case .favoritesSection: return ObjectIcon(symbolName: "star.fill", tint: .yellow)
        case .column: return ObjectIcon(symbolName: "rectangle.portrait.fill", tint: .teal)
        case .primaryKey: return ObjectIcon(symbolName: "key.fill", tint: .yellow)
        case .index: return ObjectIcon(symbolName: "list.bullet.rectangle.fill", tint: .mint)
        case .foreignKey: return ObjectIcon(symbolName: "link.circle.fill", tint: .indigo)
        case .checkConstraint: return ObjectIcon(symbolName: "checkmark.shield.fill", tint: .green)
        // A group under a table is drawn like a section: a folder in the hue of what it holds.
        case .tableDetailGroup(let group):
            return ObjectIcon(symbolName: "folder.fill", tint: colorfulIcon(for: Self.detailKind(of: group)).tint)
        case .serverObject(let symbolName): return ObjectIcon(symbolName: symbolName, tint: .gray)
        }
    }

    /// The kind of row a detail group under a table holds.
    private static func detailKind(of group: TableDetailGroupKind) -> ObjectIconKind {
        switch group {
        case .columns: return .column
        case .indexes: return .index
        case .foreignKeys: return .foreignKey
        case .checks: return .checkConstraint
        case .triggers: return .trigger
        case .partitions: return .partition
        }
    }

    private static func colorfulRelation(_ type: TableInfo.TableType) -> ObjectIcon {
        switch type {
        case .table: return ObjectIcon(symbolName: "tablecells.fill", tint: .blue)
        case .view: return ObjectIcon(symbolName: "eyeglasses", tint: .cyan)
        case .materializedView: return ObjectIcon(symbolName: "eyeglasses", tint: .indigo)
        case .foreignTable: return ObjectIcon(symbolName: "link.circle.fill", tint: .blue)
        case .systemTable: return ObjectIcon(symbolName: "tablecells.fill.badge.ellipsis", tint: .gray)
        case .partitionedTable: return ObjectIcon(symbolName: "rectangle.split.3x1.fill", tint: .blue)
        case .externalTable: return ObjectIcon(symbolName: "externaldrive.connected.to.line.below.fill", tint: .blue)
        case .sequence: return ObjectIcon(symbolName: "number.square.fill", tint: .mint)
        }
    }
}
