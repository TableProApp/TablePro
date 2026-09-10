//
//  TableRowLogicTests.swift
//  TableProTests
//
//  Tests for TableRow computed property logic extracted into TableRowLogic.
//

import TableProPluginKit
import Testing

@testable import TablePro

@Suite("TableRowLogicTests")
struct TableRowLogicTests {
    // MARK: - Accessibility Label

    @Test("Normal table accessibility label")
    func accessibilityLabelNormalTable() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        let label = TableRowLogic.accessibilityLabel(table: table, isPendingDelete: false, isPendingTruncate: false)
        #expect(label == "Table: users")
    }

    @Test("Normal view accessibility label")
    func accessibilityLabelNormalView() {
        let table = TestFixtures.makeTableInfo(name: "my_view", type: .view)
        let label = TableRowLogic.accessibilityLabel(table: table, isPendingDelete: false, isPendingTruncate: false)
        #expect(label == "View: my_view")
    }

    @Test("Pending delete accessibility label")
    func accessibilityLabelPendingDelete() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        let label = TableRowLogic.accessibilityLabel(table: table, isPendingDelete: true, isPendingTruncate: false)
        #expect(label == "Table: users, pending delete")
    }

    @Test("Pending truncate accessibility label")
    func accessibilityLabelPendingTruncate() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        let label = TableRowLogic.accessibilityLabel(table: table, isPendingDelete: false, isPendingTruncate: true)
        #expect(label == "Table: users, pending truncate")
    }

    @Test("Both pending — delete takes priority")
    func accessibilityLabelBothPendingDeleteWins() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        let label = TableRowLogic.accessibilityLabel(table: table, isPendingDelete: true, isPendingTruncate: true)
        #expect(label == "Table: users, pending delete")
    }

    @Test("View pending delete accessibility label")
    func accessibilityLabelViewPendingDelete() {
        let table = TestFixtures.makeTableInfo(name: "my_view", type: .view)
        let label = TableRowLogic.accessibilityLabel(table: table, isPendingDelete: true, isPendingTruncate: false)
        #expect(label == "View: my_view, pending delete")
    }

    @Test("Favorite table accessibility label")
    func accessibilityLabelFavoriteTable() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        let label = TableRowLogic.accessibilityLabel(table: table, isPendingDelete: false, isPendingTruncate: false, isFavorite: true)
        #expect(label == "Table: users, favorite")
    }

    // MARK: - Icon Name per Kind

    @Test("Icon name per table kind")
    func iconNamePerKind() {
        #expect(TableRowLogic.iconName(for: .table) == "tablecells")
        #expect(TableRowLogic.iconName(for: .view) == "eye")
        #expect(TableRowLogic.iconName(for: .materializedView) == "square.stack.3d.up")
        #expect(TableRowLogic.iconName(for: .foreignTable) == "link")
        #expect(TableRowLogic.iconName(for: .systemTable) == "tablecells.badge.ellipsis")
    }

    // MARK: - Accessibility Label per Kind

    @Test("Materialized view accessibility label")
    func accessibilityLabelMaterializedView() {
        let table = TestFixtures.makeTableInfo(name: "daily_revenue", type: .materializedView)
        let label = TableRowLogic.accessibilityLabel(table: table, isPendingDelete: false, isPendingTruncate: false)
        #expect(label == "Materialized View: daily_revenue")
    }

    @Test("Foreign table accessibility label")
    func accessibilityLabelForeignTable() {
        let table = TestFixtures.makeTableInfo(name: "remote_users", type: .foreignTable)
        let label = TableRowLogic.accessibilityLabel(table: table, isPendingDelete: false, isPendingTruncate: false)
        #expect(label == "Foreign Table: remote_users")
    }

    @Test("System table accessibility label")
    func accessibilityLabelSystemTable() {
        let table = TestFixtures.makeTableInfo(name: "pg_class", type: .systemTable)
        let label = TableRowLogic.accessibilityLabel(table: table, isPendingDelete: false, isPendingTruncate: false)
        #expect(label == "System Table: pg_class")
    }

    @Test("External table accessibility label")
    func accessibilityLabelExternalTable() {
        let table = TestFixtures.makeTableInfo(name: "customers", type: .externalTable)
        let label = TableRowLogic.accessibilityLabel(table: table, isPendingDelete: false, isPendingTruncate: false)
        #expect(label == "External Table: customers")
    }

    @Test("External table uses an icon distinct from a local table")
    func externalTableIconIsDistinct() {
        #expect(TableRowLogic.iconName(for: .externalTable) != TableRowLogic.iconName(for: .table))
    }

    // MARK: - Leading Icon Visibility

    @Test("Leading icon shows when object icons are enabled")
    func leadingIconShownWhenEnabled() {
        #expect(TableRowLogic.showsLeadingIcon(showObjectIcons: true, isPendingTruncate: false, isPendingDelete: false))
    }

    @Test("Leading icon hides when object icons are disabled")
    func leadingIconHiddenWhenDisabled() {
        #expect(!TableRowLogic.showsLeadingIcon(showObjectIcons: false, isPendingTruncate: false, isPendingDelete: false))
    }

    @Test("Pending delete keeps the leading slot when object icons are disabled")
    func leadingIconSurvivesPendingDelete() {
        #expect(TableRowLogic.showsLeadingIcon(showObjectIcons: false, isPendingTruncate: false, isPendingDelete: true))
    }

    @Test("Pending truncate keeps the leading slot when object icons are disabled")
    func leadingIconSurvivesPendingTruncate() {
        #expect(TableRowLogic.showsLeadingIcon(showObjectIcons: false, isPendingTruncate: true, isPendingDelete: false))
    }

    @Test("Hiding icons leaves the accessibility label naming the object kind")
    func accessibilityLabelIndependentOfIconVisibility() {
        let view = TestFixtures.makeTableInfo(name: "active_users", type: .view)
        #expect(TableRowLogic.accessibilityLabel(table: view, isPendingDelete: false, isPendingTruncate: false) == "View: active_users")
        #expect(!TableRowLogic.showsLeadingIcon(showObjectIcons: false, isPendingTruncate: false, isPendingDelete: false))
    }
}
