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

    @Test("Normal table icon color is blue")
    func iconColorNormalTable() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: false, isPendingTruncate: false) == .blue)
    }

    @Test("Normal view icon color is purple")
    func iconColorNormalView() {
        let table = TestFixtures.makeTableInfo(name: "v", type: .view)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: false, isPendingTruncate: false) == .purple)
    }

    @Test("Pending delete table icon color is red")
    func iconColorPendingDeleteTable() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: true, isPendingTruncate: false) == .red)
    }

    @Test("Pending truncate table icon color is orange")
    func iconColorPendingTruncateTable() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: false, isPendingTruncate: true) == .orange)
    }

    @Test("Pending delete view icon color is red")
    func iconColorPendingDeleteView() {
        let table = TestFixtures.makeTableInfo(name: "v", type: .view)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: true, isPendingTruncate: false) == .red)
    }

    @Test("Both pending — delete wins for icon color")
    func iconColorBothPendingDeleteWins() {
        let table = TestFixtures.makeTableInfo(name: "users", type: .table)
        #expect(TableRowLogic.iconColor(table: table, isPendingDelete: true, isPendingTruncate: true) == .red)
    }

    // MARK: - Text Color

    @Test("Normal text color is primary")
    func textColorNormal() {
        #expect(TableRowLogic.textColor(isPendingDelete: false, isPendingTruncate: false) == .primary)
    }

    @Test("Pending delete text color is red")
    func textColorPendingDelete() {
        #expect(TableRowLogic.textColor(isPendingDelete: true, isPendingTruncate: false) == .red)
    }

    @Test("Pending truncate text color is orange")
    func textColorPendingTruncate() {
        #expect(TableRowLogic.textColor(isPendingDelete: false, isPendingTruncate: true) == .orange)
    }

    @Test("Both pending — delete wins for text color")
    func textColorBothPendingDeleteWins() {
        #expect(TableRowLogic.textColor(isPendingDelete: true, isPendingTruncate: true) == .red)
    }
}
