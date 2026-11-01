//
//  ColumnCharacterSetMenusTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct ColumnCharacterSetMenusTests {
    private static let catalog = TableOptionsCatalog(
        characterSets: [
            TableCharacterSet(
                name: "latin1",
                defaultCollation: "latin1_swedish_ci",
                collations: ["latin1_bin", "latin1_swedish_ci"],
                description: nil
            ),
            TableCharacterSet(
                name: "utf8mb4",
                defaultCollation: "utf8mb4_0900_ai_ci",
                collations: ["utf8mb4_0900_ai_ci", "utf8mb4_bin", "utf8mb4_unicode_ci"],
                description: nil
            ),
        ],
        engines: ["InnoDB"],
        defaultEngine: "InnoDB"
    )

    private static let loaded = ColumnCharacterSetMenus.Context(catalog: .loaded(catalog), tableCharacterSet: "utf8mb4")

    private func column(
        _ type: String = "VARCHAR(64)",
        charset: String? = "latin1",
        collation: String? = "latin1_swedish_ci"
    ) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(), name: "name", dataType: type, isNullable: true, defaultValue: nil,
            autoIncrement: false, unsigned: false, comment: nil, collation: collation,
            onUpdate: nil, charset: charset, extra: nil, isPrimaryKey: false
        )
    }

    private func values(_ options: [GridMenuOption]?) -> [String] {
        (options ?? []).compactMap(\.sql)
    }

    private func titles(_ options: [GridMenuOption]?) -> [String] {
        (options ?? []).compactMap { option in
            switch option {
            case .value(let title, _): return title
            case .sectionHeader(let title): return title
            case .clear(let title), .custom(let title): return title
            }
        }
    }

    // MARK: - Menus

    @Test("The Charset menu lists the server's character sets after the table default")
    func characterSetMenuListsTheCatalog() {
        let options = ColumnCharacterSetMenus.options(for: .charset, column: column(), context: Self.loaded)
        #expect(values(options) == ["", "latin1", "utf8mb4"])
        #expect(titles(options).first == String(localized: "Table Default"))
    }

    @Test("The Collation menu lists only the row's character set, its default marked")
    func collationMenuFollowsTheRow() {
        let options = ColumnCharacterSetMenus.options(for: .collation, column: column(), context: Self.loaded)
        #expect(values(options) == ["latin1_bin", "latin1_swedish_ci"])
        #expect(titles(options).contains(TableOptionsForm.collationTitle("latin1_swedish_ci", isDefault: true)))
        #expect(!values(options).contains("utf8mb4_bin"))
    }

    @Test("A row with no character set of its own lists the table's collations")
    func collationMenuFallsBackToTheTable() {
        let options = ColumnCharacterSetMenus.options(
            for: .collation, column: column(charset: nil, collation: nil), context: Self.loaded
        )
        #expect(values(options) == ["utf8mb4_0900_ai_ci", "utf8mb4_bin", "utf8mb4_unicode_ci"])
    }

    @Test("A name the catalog does not list stays an item, so the cell's value is always in its menu")
    func currentValueStaysAnItem() {
        let options = ColumnCharacterSetMenus.options(
            for: .charset, column: column(charset: "utf8", collation: "utf8_general_ci"), context: Self.loaded
        )
        #expect(values(options).contains("utf8"))
    }

    @Test("A type with no character set has no menu and both cells are read-only", arguments: ["INT", "VARBINARY(16)", "JSON"])
    func nonTextTypeIsReadOnly(type: String) {
        let integer = column(type, charset: nil, collation: nil)
        #expect(ColumnCharacterSetMenus.options(for: .charset, column: integer, context: Self.loaded) == nil)
        #expect(ColumnCharacterSetMenus.options(for: .collation, column: integer, context: Self.loaded) == nil)
        #expect(ColumnCharacterSetMenus.locks(.charset, column: integer, catalog: Self.loaded.catalog))
        #expect(ColumnCharacterSetMenus.locks(.collation, column: integer, catalog: Self.loaded.catalog))
        #expect(ColumnCharacterSetMenus.entry("latin1", for: .charset, column: integer, context: Self.loaded) == .refused)
    }

    @Test("A catalog that failed leaves the current value, read-only, never free text")
    func failedCatalogIsReadOnly() {
        let context = ColumnCharacterSetMenus.Context(catalog: .failed("timeout"), tableCharacterSet: nil)
        let options = ColumnCharacterSetMenus.options(for: .charset, column: column(), context: context)
        #expect(values(options) == ["latin1"])
        #expect(titles(options).first == String(localized: "Couldn't read the character sets"))
        #expect(ColumnCharacterSetMenus.locks(.charset, column: column(), catalog: context.catalog))
        #expect(ColumnCharacterSetMenus.entry("utf8mb4", for: .charset, column: column(), context: context) == .refused)
    }

    @Test("An engine whose driver has no catalog keeps the plain text cell")
    func noCatalogKeepsFreeText() {
        let context = ColumnCharacterSetMenus.Context(catalog: .loaded(nil), tableCharacterSet: nil)
        #expect(!ColumnCharacterSetMenus.offersMenus(context.catalog))
        #expect(ColumnCharacterSetMenus.options(for: .charset, column: column(), context: context) == nil)
        #expect(!ColumnCharacterSetMenus.locks(.charset, column: column(), catalog: context.catalog))
        #expect(ColumnCharacterSetMenus.entry("anything", for: .charset, column: column(), context: context) == .unchecked)
    }

    // MARK: - Entries

    @Test("Picking a character set takes its default collation in the same write")
    func characterSetTakesItsDefaultCollation() {
        let entry = ColumnCharacterSetMenus.entry("UTF8MB4", for: .charset, column: column(), context: Self.loaded)
        #expect(entry == .set(characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci"))
    }

    @Test("A name the server does not have is refused")
    func unknownNameIsRefused() {
        #expect(ColumnCharacterSetMenus.entry("klingon", for: .charset, column: column(), context: Self.loaded) == .refused)
        #expect(ColumnCharacterSetMenus.entry("klingon_ci", for: .collation, column: column(), context: Self.loaded) == .refused)
    }

    @Test("Picking the character set the column has keeps its collation")
    func sameCharacterSetIsUnchanged() {
        let binary = column(collation: "latin1_bin")
        #expect(ColumnCharacterSetMenus.entry("latin1", for: .charset, column: binary, context: Self.loaded) == .unchanged)
    }

    @Test("A collation from another character set moves the column to that set")
    func foreignCollationMovesTheSet() {
        let entry = ColumnCharacterSetMenus.entry("utf8mb4_bin", for: .collation, column: column(), context: Self.loaded)
        #expect(entry == .set(characterSet: "utf8mb4", collation: "utf8mb4_bin"))
    }

    @Test("Table Default clears both, so the column takes the table's")
    func emptyClearsBoth() {
        #expect(ColumnCharacterSetMenus.entry("", for: .charset, column: column(), context: Self.loaded)
            == .set(characterSet: nil, collation: nil))
    }

    // MARK: - Row provider and the write

    @Test("Charset and Collation are row-dependent menus only while the grid picks from a catalog")
    func rowProviderMarksTheCells() throws {
        let manager = StructureChangeManager()
        manager.workingColumns = [column()]
        let picking = StructureRowProvider(
            changeManager: manager, tab: .columns, databaseType: .mysql,
            serverSupport: .unrestricted, picksCharacterSets: true
        )
        let charset = try #require(picking.orderedColumnFields.firstIndex(of: .charset))
        let collation = try #require(picking.orderedColumnFields.firstIndex(of: .collation))
        #expect(picking.rowDependentDropdownColumns == [charset, collation])
        #expect(picking.dropdownColumns.isSuperset(of: [charset, collation]))

        let plain = StructureRowProvider(changeManager: manager, tab: .columns, databaseType: .mysql, serverSupport: .unrestricted)
        #expect(plain.rowDependentDropdownColumns.isEmpty)
    }

    @Test("A grid pick writes the character set and its default collation together")
    func gridPickStagesThePair() throws {
        let manager = StructureChangeManager()
        manager.workingColumns = [column()]
        let fields: [StructureColumnField] = [.name, .type, .charset, .collation]
        let charsetField = try #require(fields.firstIndex(of: .charset))

        #expect(!StructureGridEdits.refuses(
            "utf8mb4", field: charsetField, sourceIndex: 0, tab: .columns,
            manager: manager, orderedFields: fields, characterSets: Self.loaded
        ))
        StructureGridEdits.apply(
            "utf8mb4", field: charsetField, sourceIndex: 0, tab: .columns, manager: manager,
            orderedFields: fields, connection: TestFixtures.makeConnection(type: .mysql), characterSets: Self.loaded
        )

        let edited = try #require(manager.workingColumns.first)
        #expect(edited.charset == "utf8mb4")
        #expect(edited.collation == "utf8mb4_0900_ai_ci")
    }

    @Test("A typed name the catalog lacks never reaches the column")
    func refusedTextLeavesTheColumn() throws {
        let manager = StructureChangeManager()
        manager.workingColumns = [column()]
        let fields: [StructureColumnField] = [.name, .type, .charset, .collation]
        let charsetField = try #require(fields.firstIndex(of: .charset))

        #expect(StructureGridEdits.refuses(
            "utf8mb5", field: charsetField, sourceIndex: 0, tab: .columns,
            manager: manager, orderedFields: fields, characterSets: Self.loaded
        ))
        StructureGridEdits.apply(
            "utf8mb5", field: charsetField, sourceIndex: 0, tab: .columns, manager: manager,
            orderedFields: fields, connection: TestFixtures.makeConnection(type: .mysql), characterSets: Self.loaded
        )
        #expect(manager.workingColumns.first?.charset == "latin1")
    }
}
