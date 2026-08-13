//
//  DatabaseTreeTypeSelectTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@Suite("Database tree type select")
struct DatabaseTreeTypeSelectTests {
    private static let upArrow: UInt16 = 126
    private static let downArrow: UInt16 = 125
    private static let letterO: UInt16 = 31

    @Test("Arrow keys count as navigation")
    func arrowsNavigate() {
        #expect(DatabaseTreeTypeSelect.isArrowNavigation(type: .keyDown, keyCode: Self.upArrow))
        #expect(DatabaseTreeTypeSelect.isArrowNavigation(type: .keyDown, keyCode: Self.downArrow))
        #expect(DatabaseTreeTypeSelect.isArrowNavigation(type: .keyUp, keyCode: Self.upArrow))
    }

    @Test("A typed letter does not count as navigation")
    func lettersDoNotNavigate() {
        #expect(DatabaseTreeTypeSelect.isArrowNavigation(type: .keyDown, keyCode: Self.letterO) == false)
    }

    @Test("A mouse event does not count as navigation")
    func mouseDoesNotNavigate() {
        #expect(DatabaseTreeTypeSelect.isArrowNavigation(type: .leftMouseDown, keyCode: Self.upArrow) == false)
    }

    @Test("Group and status rows have no type select string")
    func groupRowsHaveNoMatchString() {
        #expect(DatabaseTreeTypeSelect.matchString(for: .recentSection) == nil)
        #expect(DatabaseTreeTypeSelect.matchString(for: .status(.loading)) == nil)
    }

    @Test("A schema row matches on its schema name")
    func schemaMatchesOnName() {
        let kind = DatabaseTreeNode.Kind.schema(database: "shop", schema: "public")
        #expect(DatabaseTreeTypeSelect.matchString(for: kind) == "public")
    }

    @Test("A table row matches on its table name")
    func tableMatchesOnName() {
        let ref = DatabaseTreeTableRef(
            database: "shop",
            schema: "public",
            table: TestFixtures.makeTableInfo(name: "orders")
        )
        #expect(DatabaseTreeTypeSelect.matchString(for: .table(ref)) == "orders")
        #expect(DatabaseTreeTypeSelect.matchString(for: .recentTable(ref)) == "orders")
    }
}
