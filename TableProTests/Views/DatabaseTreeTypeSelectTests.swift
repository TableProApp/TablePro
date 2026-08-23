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

    /// Reading `keyCode` off a real mouse event raises, and the raise unwound through AppKit's
    /// mouse tracking: clicking a table selected it but never opened it. The pure test above cannot
    /// catch that, because it never touches an `NSEvent`.
    @Test("A real mouse event is answered without reading its key code")
    func realMouseEventDoesNotReadKeyCode() throws {
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        #expect(DatabaseTreeTypeSelect.isArrowNavigation(event) == false)
    }

    @Test("A real arrow key event counts as navigation")
    func realArrowEventNavigates() throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: Self.downArrow
            )
        )
        #expect(DatabaseTreeTypeSelect.isArrowNavigation(event))
    }

    @Test("Group and status rows have no type select string")
    func groupRowsHaveNoMatchString() {
        #expect(DatabaseTreeTypeSelect.matchString(for: .recentSection) == nil)
        #expect(DatabaseTreeTypeSelect.matchString(for: .status(.loading)) == nil)
        #expect(DatabaseTreeTypeSelect.matchString(for: .objectKindSection(.table)) == nil)
    }

    /// A container's object group is selectable, so arrow keys stop on it. Type-select has to reach
    /// the same row, on the title the row draws rather than the kind's own name.
    @Test("A container object group matches on the title its row draws")
    func containerObjectGroupMatchesOnItsTitle() {
        let tables = DatabaseTreeObjectGroup(database: "shop", schema: "public", kind: .table)
        let views = DatabaseTreeObjectGroup(database: "shop", schema: "public", kind: .view)
        #expect(
            DatabaseTreeTypeSelect.matchString(for: .containerObjectKindSection(tables))
                == SidebarObjectKind.table.pluralDisplayName
        )
        #expect(
            DatabaseTreeTypeSelect.matchString(
                for: .containerObjectKindSection(tables), tableEntityName: "Collections"
            ) == "Collections"
        )
        #expect(
            DatabaseTreeTypeSelect.matchString(
                for: .containerObjectKindSection(views), tableEntityName: "Collections"
            ) == SidebarObjectKind.view.pluralDisplayName
        )
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
