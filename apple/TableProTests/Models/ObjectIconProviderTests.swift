//
//  ObjectIconProviderTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import Testing

@MainActor
struct ObjectIconProviderTests {
    /// Every glyph the sidebar drew for each kind before the icon style existed.
    private static let standardSymbols: [(ObjectIconKind, String)] = [
        (.database, "cylinder"),
        (.systemDatabase, "gearshape"),
        (.schema, "folder"),
        (.externalSchema, "folder.badge.gearshape"),
        (.relation(.table), "tablecells"),
        (.relation(.view), "eye"),
        (.relation(.materializedView), "square.stack.3d.up"),
        (.relation(.foreignTable), "link"),
        (.relation(.systemTable), "tablecells.badge.ellipsis"),
        (.relation(.partitionedTable), "rectangle.split.3x1"),
        (.relation(.externalTable), "externaldrive.connected.to.line.below"),
        (.relation(.sequence), "number"),
        (.partition, "rectangle.split.3x1.fill"),
        (.routine(.function), "function"),
        (.routine(.procedure), "curlybraces.square"),
        (.trigger, "bolt"),
        (.userType(.enumeration), "list.bullet"),
        (.userType(.composite), "rectangle.split.3x1"),
        (.userType(.domain), "checkmark.seal"),
        (.userType(.range), "arrow.left.and.right.square"),
        (.userType(.aliasType), "character.textbox"),
        (.userType(.tableType), "tablecells"),
        (.userType(.clrType), "shippingbox"),
        (.userType(.udt), "rectangle.split.3x1"),
        (.userType(.other), "cube"),
        (.section(.table), "tablecells"),
        (.section(.view), "eye"),
        (.section(.materializedView), "square.stack.3d.up"),
        (.section(.foreignTable), "link"),
        (.section(.sequence), "number"),
        (.section(.procedure), "curlybraces.square"),
        (.section(.function), "function"),
        (.section(.trigger), "bolt"),
        (.section(.type), "cube"),
        (.tableFolder, "folder"),
        (.query, "doc.text"),
        (.savedQuery, "star"),
        (.user, "person.2"),
    ]

    private static let colorfulIcons: [(ObjectIconKind, ObjectIcon)] = [
        (.database, ObjectIcon(symbolName: "cylinder.split.1x2.fill", tint: .green)),
        (.systemDatabase, ObjectIcon(symbolName: "gearshape.fill", tint: .gray)),
        (.schema, ObjectIcon(symbolName: "square.stack.3d.up.fill", tint: .teal)),
        (.externalSchema, ObjectIcon(symbolName: "square.stack.3d.forward.dottedline.fill", tint: .teal)),
        (.relation(.table), ObjectIcon(symbolName: "tablecells.fill", tint: .blue)),
        (.relation(.view), ObjectIcon(symbolName: "eyeglasses", tint: .cyan)),
        (.relation(.materializedView), ObjectIcon(symbolName: "eyeglasses", tint: .indigo)),
        (.relation(.foreignTable), ObjectIcon(symbolName: "link.circle.fill", tint: .blue)),
        (.relation(.systemTable), ObjectIcon(symbolName: "tablecells.fill.badge.ellipsis", tint: .gray)),
        (.relation(.partitionedTable), ObjectIcon(symbolName: "rectangle.split.3x1.fill", tint: .blue)),
        (.relation(.externalTable), ObjectIcon(symbolName: "externaldrive.connected.to.line.below.fill", tint: .blue)),
        (.relation(.sequence), ObjectIcon(symbolName: "number.square.fill", tint: .mint)),
        (.partition, ObjectIcon(symbolName: "rectangle.split.3x1.fill", tint: .blue)),
        (.routine(.function), ObjectIcon(symbolName: "function", tint: .purple)),
        (.routine(.procedure), ObjectIcon(symbolName: "curlybraces.square.fill", tint: .orange)),
        (.trigger, ObjectIcon(symbolName: "bolt.fill", tint: .yellow)),
        (.userType(.enumeration), ObjectIcon(symbolName: "t.square.fill", tint: .pink)),
        (.userType(.other), ObjectIcon(symbolName: "t.square.fill", tint: .pink)),
        (.section(.table), ObjectIcon(symbolName: "folder.fill", tint: .blue)),
        (.section(.view), ObjectIcon(symbolName: "folder.fill", tint: .cyan)),
        (.section(.function), ObjectIcon(symbolName: "folder.fill", tint: .purple)),
        (.section(.type), ObjectIcon(symbolName: "folder.fill", tint: .pink)),
        (.tableFolder, ObjectIcon(symbolName: "folder.fill", tint: .blue)),
        (.query, ObjectIcon(symbolName: "doc.text.fill", tint: .orange)),
        (.savedQuery, ObjectIcon(symbolName: "doc.text.fill", tint: .orange)),
        (.user, ObjectIcon(symbolName: "person.fill", tint: .brown)),
    ]

    /// Every kind there is, so a glyph added to either style is checked against the system.
    private static var everyKind: [ObjectIconKind] {
        var kinds: [ObjectIconKind] = [
            .database, .systemDatabase, .schema, .externalSchema, .partition, .trigger, .tableFolder,
            .query, .savedQuery, .user,
        ]
        kinds += TableInfo.TableType.allCases.map { .relation($0) }
        kinds += RoutineInfo.Kind.allCases.map { .routine($0) }
        kinds += UserDefinedTypeInfo.Kind.allCases.map { .userType($0) }
        kinds += SidebarObjectKind.allCases.map { .section($0) }
        return kinds
    }

    @Test("The standard style draws today's glyph for every kind, untinted")
    func standardStyleKeepsTodaysGlyphs() {
        for (kind, symbol) in Self.standardSymbols {
            #expect(ObjectIconProvider.icon(for: kind, style: .standard) == ObjectIcon(symbolName: symbol), "\(kind)")
        }
        #expect(Self.standardSymbols.count == Self.everyKind.count)
    }

    @Test("The standard style draws a surface's own glyph when the surface names one")
    func standardStyleKeepsASurfacesGlyph() {
        let icon = ObjectIconProvider.icon(for: .relation(.systemTable), style: .standard, standard: "gearshape")
        let colorful = ObjectIconProvider.icon(for: .relation(.systemTable), style: .colorful, standard: "gearshape")

        #expect(icon == ObjectIcon(symbolName: "gearshape"))
        #expect(colorful.symbolName == "tablecells.fill.badge.ellipsis")
    }

    @Test("The colorful style gives each kind its glyph and its hue")
    func colorfulStylePinsTheSet() {
        for (kind, icon) in Self.colorfulIcons {
            #expect(ObjectIconProvider.icon(for: kind, style: .colorful) == icon, "\(kind)")
        }
    }

    @Test("Every kind is tinted in the colorful style")
    func colorfulStyleTintsEveryKind() {
        for kind in Self.everyKind {
            #expect(ObjectIconProvider.icon(for: kind, style: .colorful).tint != nil, "\(kind)")
        }
    }

    @Test("A section folder wears the hue of the objects it holds")
    func sectionsTakeTheirKindsHue() {
        for kind in SidebarObjectKind.allCases {
            let section = ObjectIconProvider.icon(for: .section(kind), style: .colorful)
            let object = ObjectIconProvider.icon(for: ObjectIconKind(kind), style: .colorful)
            #expect(section.symbolName == "folder.fill")
            #expect(section.tint == object.tint, "\(kind)")
        }
    }

    @Test("Every glyph in both styles is a symbol the system has")
    func everySymbolExists() {
        for kind in Self.everyKind {
            for style in ObjectIconStyle.allCases {
                let name = ObjectIconProvider.icon(for: kind, style: style).symbolName
                #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
            }
        }
    }

    @Test("Each hue is the system color, so it follows the appearance and Increase Contrast")
    func tintsAreSystemColors() {
        #expect(ObjectIconTint.blue.nsColor == .systemBlue)
        #expect(ObjectIconTint.cyan.nsColor == .systemCyan)
        #expect(ObjectIconTint.mint.nsColor == .systemMint)
        #expect(ObjectIconTint.brown.nsColor == .systemBrown)
        #expect(Set(ObjectIconTint.allCases.map(\.nsColor)).count == ObjectIconTint.allCases.count)
    }

    // MARK: - Surfaces

    @Test("The quick switcher keeps its own glyphs in the standard style and the kind's in the colorful one")
    func quickSwitcherItems() {
        var sequence = QuickSwitcherItem(frecencyKey: "s", name: "order_id_seq", kind: .table, subtitle: "")
        sequence.tableType = .sequence
        let system = QuickSwitcherItem(frecencyKey: "p", name: "pg_class", kind: .systemTable, subtitle: "")
        let saved = QuickSwitcherItem(frecencyKey: "q", name: "Top customers", kind: .savedQuery, subtitle: "")
        let history = QuickSwitcherItem(frecencyKey: "h", name: "SELECT 1", kind: .queryHistory, subtitle: "")

        #expect(sequence.icon(style: .standard) == ObjectIcon(symbolName: "tablecells"))
        #expect(system.icon(style: .standard) == ObjectIcon(symbolName: "gearshape"))
        #expect(saved.icon(style: .standard) == ObjectIcon(symbolName: "star"))
        #expect(history.icon(style: .standard) == ObjectIcon(symbolName: "clock.arrow.circlepath"))

        #expect(sequence.icon(style: .colorful) == ObjectIcon(symbolName: "number.square.fill", tint: .mint))
        #expect(system.icon(style: .colorful) == ObjectIcon(symbolName: "tablecells.fill.badge.ellipsis", tint: .gray))
        #expect(saved.icon(style: .colorful) == ObjectIcon(symbolName: "doc.text.fill", tint: .orange))
        #expect(history.icon(style: .colorful) == ObjectIcon(symbolName: "clock.arrow.circlepath"))
    }

    @Test("The recent tab switcher keeps its own glyphs in the standard style and the kind's in the colorful one")
    func recentTabs() {
        var view = QueryTab(title: "active_orders", tabType: .table, tableName: "active_orders")
        view.tableContext.objectType = .materializedView
        view.tableContext.isView = true
        var source = QueryTab(title: "touch", tabType: .objectSource)
        source.display.objectRef = DatabaseObjectRef(kind: .function, name: "touch", database: "shop")
        let diagram = QueryTab(title: "ER Diagram", tabType: .erDiagram)

        #expect(MainSplitViewController.recentTabIcon(for: view, style: .standard) == ObjectIcon(symbolName: "eye"))
        #expect(MainSplitViewController.recentTabIcon(for: source, style: .standard)
            == ObjectIcon(symbolName: "curlybraces.square"))
        #expect(MainSplitViewController.recentTabIcon(for: view, style: .colorful)
            == ObjectIcon(symbolName: "eyeglasses", tint: .indigo))
        #expect(MainSplitViewController.recentTabIcon(for: source, style: .colorful)
            == ObjectIcon(symbolName: "function", tint: .purple))
        #expect(MainSplitViewController.recentTabIcon(for: diagram, style: .colorful)
            == MainSplitViewController.recentTabIcon(for: diagram, style: .standard))
        #expect(MainSplitViewController.recentTabIcon(for: diagram, style: .colorful).tint == nil)
    }

    @Test("An Objects row draws what the sidebar draws, a type as the Types section does")
    func objectsListItems() {
        let enumType = DatabaseObjectRef(kind: .userType, name: "mood", database: "shop", typeKind: .enumeration)

        #expect(ObjectListingItem.relation(name: "orders", schema: nil, type: .view).iconKind == .relation(.view))
        #expect(ObjectListingItem.sourced(enumType).iconKind == .userType(.other))
        #expect(ObjectIconProvider.icon(for: ObjectListingItem.sourced(enumType).iconKind, style: .standard)
            == ObjectIcon(symbolName: "cube"))
    }
}
