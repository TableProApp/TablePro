//
//  EditorTabLabelResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct EditorTabLabelResolverTests {
    private func tableTab(_ name: String, database: String = "", schema: String? = nil) -> QueryTab {
        var tab = QueryTab(title: name, tabType: .table, tableName: name)
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    @Test("A title no other tab uses stays bare")
    func leavesUniqueTitlesAlone() {
        let tabs = [tableTab("orders", database: "app"), tableTab("customers", database: "logs")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(labels[tabs[0].id]?.text == "orders")
        #expect(labels[tabs[1].id]?.text == "customers")
    }

    @Test("The same table open in two databases is qualified on both tabs")
    func qualifiesACollisionAcrossDatabases() {
        let tabs = [
            tableTab("role_ability", database: "banshi_test"),
            tableTab("role_ability", database: "banshi_online"),
        ]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(labels[tabs[0].id]?.text == "banshi_test.role_ability")
        #expect(labels[tabs[1].id]?.text == "banshi_online.role_ability")
    }

    @Test("Two tabs sharing a title inside one database stay bare, because naming it tells them apart")
    func leavesACollisionInsideOneContainerAlone() {
        let tabs = [tableTab("orders", database: "app"), tableTab("orders", database: "app")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(labels[tabs[0].id]?.text == "orders")
        #expect(labels[tabs[1].id]?.text == "orders")
    }

    @Test("The description names the container even when the label did not need it")
    func describesTheContainerRegardless() {
        let tabs = [tableTab("orders", database: "app")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(labels[tabs[0].id]?.text == "orders")
        #expect(labels[tabs[0].id]?.description == "app.orders")
    }

    @Test("A tab that names no container is described by its title alone")
    func describesAContainerlessTabByItsTitle() {
        let tabs = [tableTab("orders")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: nil)

        #expect(labels[tabs[0].id]?.text == "orders")
        #expect(labels[tabs[0].id]?.description == "orders")
    }

    @Test("A title already carrying its schema is not qualified twice")
    func doesNotQualifyTwice() {
        var reporting = tableTab("orders", database: "app", schema: "reporting")
        reporting.title = "reporting.orders"
        let tabs = [reporting, tableTab("orders", database: "app", schema: "public")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .schema)

        #expect(labels[tabs[0].id]?.description == "reporting.orders")
    }

    @Test("A tab that names no object is never qualified, whatever database it was opened from")
    func neverQualifiesANonObjectTab() {
        var dashboard = QueryTab(title: "Server Dashboard", tabType: .serverDashboard)
        dashboard.tableContext.databaseName = "app"
        var other = QueryTab(title: "Server Dashboard", tabType: .serverDashboard)
        other.tableContext.databaseName = "staging"
        let labels = EditorTabLabelResolver.resolve(tabs: [dashboard, other], target: .database)

        #expect(labels[dashboard.id]?.text == "Server Dashboard")
        #expect(labels[dashboard.id]?.description == "Server Dashboard")
        #expect(labels[other.id]?.text == "Server Dashboard")
    }

    @Test("A collision between a bound and an unbound tab qualifies only the one that can be")
    func qualifiesOnlyTheTabWithAContainer() {
        let tabs = [tableTab("orders", database: "app"), tableTab("orders")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(labels[tabs[0].id]?.text == "app.orders")
        #expect(labels[tabs[1].id]?.text == "orders")
    }

    // MARK: - Located titles

    private let shop = EditorTabTitleStyle.location(connectionName: "Shop Demo")

    @Test("The setting picks the style, and off keeps the bare name")
    func styleFollowsTheSetting() {
        #expect(EditorTabTitleStyle(showsLocation: false, connectionName: "Shop Demo") == .name)
        #expect(EditorTabTitleStyle(showsLocation: true, connectionName: "Shop Demo") == shop)
    }

    @Test("A table tab names its database and connection")
    func locatesATableTab() {
        let tabs = [tableTab("orders", database: "shop_demo")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database, style: shop)

        #expect(labels[tabs[0].id]?.text == "orders@shop_demo (Shop Demo)")
        #expect(labels[tabs[0].id]?.description == "orders@shop_demo (Shop Demo)")
        #expect(labels[tabs[0].id]?.symbolName == "tablecells")
    }

    @Test("A table outside the default schema keeps its schema in front of the name")
    func locatesASchemaQualifiedTable() {
        var reporting = tableTab("orders", database: "shop_demo", schema: "reporting")
        reporting.title = "reporting.orders"
        let labels = EditorTabLabelResolver.resolve(tabs: [reporting], target: .schema, style: shop)

        #expect(labels[reporting.id]?.text == "reporting.orders@shop_demo (Shop Demo)")
        #expect(labels[reporting.id]?.description == "reporting.orders@shop_demo (Shop Demo)")
    }

    @Test("A table in the default schema reads bare, and hovering still names the schema")
    func describesTheDefaultSchema() {
        let tabs = [tableTab("orders", database: "shop_demo", schema: "public")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .schema, style: shop)

        #expect(labels[tabs[0].id]?.text == "orders@shop_demo (Shop Demo)")
        #expect(labels[tabs[0].id]?.description == "public.orders@shop_demo (Shop Demo)")
    }

    @Test("A missing database or connection name is left out rather than drawn empty")
    func leavesOutMissingParts() {
        #expect(EditorTabLabelResolver.locationTitle(object: "orders", database: "", connectionName: "Shop Demo")
            == "orders (Shop Demo)")
        #expect(EditorTabLabelResolver.locationTitle(object: "orders", database: "shop_demo", connectionName: "")
            == "orders@shop_demo")
        #expect(EditorTabLabelResolver.locationTitle(object: "orders", database: "shop_demo", connectionName: "  ")
            == "orders@shop_demo")
        #expect(EditorTabLabelResolver.locationTitle(object: "orders", database: "", connectionName: "") == "orders")

        let tabs = [tableTab("orders")]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: nil, style: shop)
        #expect(labels[tabs[0].id]?.text == "orders (Shop Demo)")
    }

    /// The strip, not the resolver, shortens a title that does not fit, so the text stays whole and the
    /// short form carries the parts the strip keeps.
    @Test("A long title is kept whole, and its short form keeps the table and the database apart")
    func keepsLongTitlesWhole() {
        let table = String(repeating: "customer_order_line_item_", count: 4) + "archive"
        let database = String(repeating: "warehouse_reporting_", count: 3) + "replica"
        let connection = "Production Analytics Read Replica (eu-west-1)"
        let tabs = [tableTab(table, database: database)]
        let labels = EditorTabLabelResolver.resolve(
            tabs: tabs, target: .database, style: .location(connectionName: connection)
        )

        let text = labels[tabs[0].id]?.text ?? ""
        #expect(text == "\(table)@\(database) (\(connection))")
        #expect(text.hasPrefix(table))
        #expect(!text.contains("…"))
        #expect(labels[tabs[0].id]?.shortForm == EditorTabLabelResolver.ShortForm(object: table, database: "@\(database)"))
    }

    @Test("Only a located title has a short form, and one with no database keeps the object alone")
    func shortFormBelongsToLocatedTitles() {
        let tabs = [
            tableTab("orders", database: "shop_demo"),
            tableTab("audit_log"),
            QueryTab(title: "Query 1", tabType: .query),
        ]
        let located = EditorTabLabelResolver.resolve(tabs: tabs, target: .database, style: shop)
        let named = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(located[tabs[0].id]?.shortForm == EditorTabLabelResolver.ShortForm(object: "orders", database: "@shop_demo"))
        #expect(located[tabs[1].id]?.shortForm == EditorTabLabelResolver.ShortForm(object: "audit_log", database: ""))
        #expect(located[tabs[2].id]?.shortForm == nil)
        #expect(tabs.allSatisfy { named[$0.id]?.shortForm == nil })
    }

    /// Two schemas of one database hold `orders` each: the location does not tell them apart, the schema does,
    /// and the short form has to keep it.
    @Test("A short form keeps the schema a collision needs")
    func shortFormKeepsTheQualifyingSchema() {
        let tabs = [
            tableTab("orders", database: "shop_demo", schema: "sales"),
            tableTab("orders", database: "shop_demo", schema: "archive"),
        ]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .schema, style: shop)

        #expect(labels[tabs[0].id]?.text == "sales.orders@shop_demo (Shop Demo)")
        #expect(labels[tabs[0].id]?.shortForm == EditorTabLabelResolver.ShortForm(object: "sales.orders", database: "@shop_demo"))
        #expect(labels[tabs[1].id]?.shortForm?.object == "archive.orders")
    }

    @Test("A view tab carries the view glyph, and every other object kind its sidebar glyph")
    func locatesAViewWithItsGlyph() {
        var view = tableTab("active_orders", database: "shop_demo")
        view.tableContext.isView = true
        var materialized = tableTab("daily_totals", database: "shop_demo")
        materialized.tableContext.objectType = .materializedView
        let labels = EditorTabLabelResolver.resolve(tabs: [view, materialized], target: .database, style: shop)

        #expect(labels[view.id]?.text == "active_orders@shop_demo (Shop Demo)")
        #expect(labels[view.id]?.symbolName == "eye")
        #expect(labels[materialized.id]?.symbolName == TableRowLogic.iconName(for: .materializedView))
    }

    @Test("Query tabs and other kinds keep their titles and draw no glyph")
    func leavesOtherKindsAlone() {
        var query = QueryTab(title: "Query 1", tabType: .query)
        query.tableContext.databaseName = "shop_demo"
        var dashboard = QueryTab(title: "Server Dashboard", tabType: .serverDashboard)
        dashboard.tableContext.databaseName = "shop_demo"
        var listing = QueryTab(title: "Objects", tabType: .tableListing)
        listing.tableContext.databaseName = "shop_demo"
        let tabs = [query, dashboard, listing]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database, style: shop)

        for tab in tabs {
            #expect(labels[tab.id]?.text == tab.title)
            #expect(labels[tab.id]?.symbolName == nil)
        }
    }

    @Test("The bare style draws exactly what it drew before the setting existed")
    func bareStyleIsUnchanged() {
        let tabs = [
            tableTab("role_ability", database: "banshi_test"),
            tableTab("role_ability", database: "banshi_online"),
            tableTab("orders", database: "app"),
        ]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database)

        #expect(labels[tabs[0].id] == EditorTabLabelResolver.Label(
            text: "banshi_test.role_ability", description: "banshi_test.role_ability"
        ))
        #expect(labels[tabs[2].id] == EditorTabLabelResolver.Label(text: "orders", description: "app.orders"))
        #expect(tabs.allSatisfy { labels[$0.id]?.symbolName == nil })
    }

    @Test("The same table in two databases is told apart by the location alone, never qualified again")
    func locationDisambiguatesWithoutDoubling() {
        let tabs = [
            tableTab("role_ability", database: "banshi_test"),
            tableTab("role_ability", database: "banshi_online"),
        ]
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database, style: shop)

        #expect(labels[tabs[0].id]?.text == "role_ability@banshi_test (Shop Demo)")
        #expect(labels[tabs[1].id]?.text == "role_ability@banshi_online (Shop Demo)")
        #expect(labels[tabs[0].id]?.description == "role_ability@banshi_test (Shop Demo)")
    }

    @Test("A located title never reaches the tab itself, so turning the setting off restores the name")
    func locationIsNotWrittenToTheTab() {
        let tabs = [tableTab("orders", database: "shop_demo")]
        _ = EditorTabLabelResolver.resolve(tabs: tabs, target: .database, style: shop)

        #expect(tabs[0].title == "orders")
        #expect(EditorTabLabelResolver.resolve(tabs: tabs, target: .database)[tabs[0].id]?.text == "orders")
    }

    // MARK: - Object icon style

    @Test("The colorful style gives every object and query tab its kind's tinted glyph, located or not")
    func colorfulStyleTintsEveryObjectTab() {
        var view = tableTab("active_orders", database: "shop_demo")
        view.tableContext.isView = true
        let table = tableTab("orders", database: "shop_demo")
        let query = QueryTab(title: "Query 1", tabType: .query)
        var listing = QueryTab(title: "Objects", tabType: .tableListing)
        listing.display.listingKind = .function
        var source = QueryTab(title: "touch", tabType: .objectSource)
        source.display.objectRef = DatabaseObjectRef(kind: .trigger, name: "touch", database: "shop_demo")
        let tabs = [table, view, query, listing, source]

        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: .database, iconStyle: .colorful)

        #expect(labels[table.id]?.icon == ObjectIcon(symbolName: "tablecells.fill", tint: .blue))
        #expect(labels[view.id]?.icon == ObjectIcon(symbolName: "eyeglasses", tint: .cyan))
        #expect(labels[query.id]?.icon == ObjectIcon(symbolName: "doc.text.fill", tint: .orange))
        #expect(labels[listing.id]?.icon == ObjectIcon(symbolName: "folder.fill", tint: .purple))
        #expect(labels[source.id]?.icon == ObjectIcon(symbolName: "bolt.fill", tint: .yellow))
        #expect(labels[table.id]?.text == "orders")
    }

    @Test("A tool tab draws no glyph in the colorful style, and the standard style tints nothing")
    func toolTabsAndStandardStyleStayPlain() {
        let dashboard = QueryTab(title: "Server Dashboard", tabType: .serverDashboard)
        let table = tableTab("orders", database: "shop_demo")

        let colorful = EditorTabLabelResolver.resolve(tabs: [dashboard], target: .database, iconStyle: .colorful)
        let standard = EditorTabLabelResolver.resolve(tabs: [table], target: .database, style: shop, iconStyle: .standard)

        #expect(colorful[dashboard.id]?.icon == nil)
        #expect(standard[table.id]?.icon == ObjectIcon(symbolName: "tablecells"))
    }
}
