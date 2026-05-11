//
//  TableRowLogicTests.swift
//  TableProTests
//
//  Tests for TableRow computed property logic extracted into TableRowLogic.
//

import SwiftUI
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

    // MARK: - Icon Color

    @Test("Normal table icon color is system blue")
    func iconColorNormalTable() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: false, isPendingTruncate: false) == Color(nsColor: .systemBlue))
    }

    @Test("Normal view icon color is system purple")
    func iconColorNormalView() {
        let table = TestFixtures.makeTableInfo(name: "v", type: .view)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: false, isPendingTruncate: false) == Color(nsColor: .systemPurple))
    }

    @Test("Materialized view icon color is system teal")
    func iconColorMaterializedView() {
        let table = TestFixtures.makeTableInfo(name: "mv", type: .materializedView)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: false, isPendingTruncate: false) == Color(nsColor: .systemTeal))
    }

    @Test("Foreign table icon color is system indigo")
    func iconColorForeignTable() {
        let table = TestFixtures.makeTableInfo(name: "ft", type: .foreignTable)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: false, isPendingTruncate: false) == Color(nsColor: .systemIndigo))
    }

    @Test("System table icon color is system gray")
    func iconColorSystemTable() {
        let table = TestFixtures.makeTableInfo(name: "s", type: .systemTable)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: false, isPendingTruncate: false) == Color(nsColor: .systemGray))
    }

    @Test("Pending delete table icon color is system red")
    func iconColorPendingDeleteTable() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: true, isPendingTruncate: false) == Color(nsColor: .systemRed))
    }

    @Test("Pending truncate table icon color is system orange")
    func iconColorPendingTruncateTable() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: false, isPendingTruncate: true) == Color(nsColor: .systemOrange))
    }

    @Test("Pending delete view icon color is system red")
    func iconColorPendingDeleteView() {
        let table = TestFixtures.makeTableInfo(name: "v", type: .view)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: true, isPendingTruncate: false) == Color(nsColor: .systemRed))
    }

    @Test("Both pending — delete wins for icon color")
    func iconColorBothPendingDeleteWins() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: true, isPendingTruncate: true) == Color(nsColor: .systemRed))
    }

    // MARK: - Text Color

    @Test("Normal text color is primary")
    func textColorNormal() {
        #expect(TableRowLogic.textColor(isPendingDelete: false, isPendingTruncate: false) == .primary)
    }

    @Test("Pending delete text color is system red")
    func textColorPendingDelete() {
        #expect(TableRowLogic.textColor(isPendingDelete: true, isPendingTruncate: false) == Color(nsColor: .systemRed))
    }

    @Test("Pending truncate text color is system orange")
    func textColorPendingTruncate() {
        #expect(TableRowLogic.textColor(isPendingDelete: false, isPendingTruncate: true) == Color(nsColor: .systemOrange))
    }

    @Test("Both pending — delete wins for text color")
    func textColorBothPendingDeleteWins() {
        #expect(TableRowLogic.textColor(isPendingDelete: true, isPendingTruncate: true) == Color(nsColor: .systemRed))
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
}
