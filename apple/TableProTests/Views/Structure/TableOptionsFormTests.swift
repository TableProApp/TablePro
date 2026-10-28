//
//  TableOptionsFormTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct TableOptionsFormTests {
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
                collations: ["utf8mb4_0900_ai_ci", "utf8mb4_bin"],
                description: nil
            ),
        ],
        engines: ["InnoDB", "MyISAM"],
        defaultEngine: "InnoDB"
    )

    // MARK: - Pickers

    @Test("The table's own character set is an item even when the catalog does not list it")
    func characterSetKeepsTheCurrentValue() {
        #expect(TableOptionsForm.characterSets(in: Self.catalog, keeping: "utf8") == ["utf8", "latin1", "utf8mb4"])
        #expect(TableOptionsForm.characterSets(in: Self.catalog, keeping: "LATIN1") == ["latin1", "utf8mb4"])
        #expect(TableOptionsForm.characterSets(in: nil, keeping: "latin1") == ["latin1"])
    }

    @Test("Collations follow the character set, with its default marked")
    func collationsFollowTheCharacterSet() {
        let choices = TableOptionsForm.collations(in: Self.catalog, characterSet: "latin1", keeping: "latin1_bin")
        #expect(choices.map { $0.name } == ["latin1_bin", "latin1_swedish_ci"])
        #expect(choices.filter { $0.isDefault }.map { $0.name } == ["latin1_swedish_ci"])
        #expect(choices.last?.title == TableOptionsForm.collationTitle("latin1_swedish_ci", isDefault: true))
    }

    @Test("A collation the catalog lacks for the set stays an item")
    func collationKeepsTheCurrentValue() {
        let choices = TableOptionsForm.collations(in: Self.catalog, characterSet: "utf8mb4", keeping: "utf8mb4_uca1400_ai_ci")
        #expect(choices.first?.name == "utf8mb4_uca1400_ai_ci")
        #expect(choices.count == 3)
    }

    @Test("Picking a character set takes its default collation in the same value and keeps the rest")
    func selectingCharacterSetIsOneValue() {
        let options = TableOptions(
            characterSet: "latin1", collation: "latin1_bin", convertsColumns: true, autoIncrement: 42
        )
        let next = TableOptionsForm.selectingCharacterSet("utf8mb4", in: options, catalog: Self.catalog)
        #expect(next == TableOptions(
            characterSet: "utf8mb4", collation: "utf8mb4_0900_ai_ci", convertsColumns: true, autoIncrement: 42
        ))
    }

    @Test("The engine list marks the server's default")
    func enginesMarkTheDefault() {
        let engines = TableOptionsForm.engines(in: Self.catalog, keeping: nil)
        #expect(engines.map { $0.name } == ["InnoDB", "MyISAM"])
        #expect(engines.filter { $0.isDefault }.map { $0.name } == ["InnoDB"])
    }

    // MARK: - Next Auto Increment

    private func column(_ type: String, unsigned: Bool = false) -> EditableColumnDefinition {
        EditableColumnDefinition(
            id: UUID(), name: "id", dataType: type, isNullable: false, defaultValue: nil,
            autoIncrement: true, unsigned: unsigned, comment: nil, collation: nil,
            onUpdate: nil, charset: nil, extra: nil, isPrimaryKey: true
        )
    }

    @Test("The range is the AUTO_INCREMENT column's type, its own unsigned flag included")
    func rangeFollowsTheColumn() {
        #expect(AutoIncrementEntry.maximum(for: column("INT")) == 2_147_483_647)
        #expect(AutoIncrementEntry.maximum(for: column("TINYINT", unsigned: true)) == 255)
        #expect(AutoIncrementEntry.maximum(for: column("BIGINT UNSIGNED")) == UInt64.max)
    }

    @Test("A whole number in the range is a counter")
    func validCounter() {
        #expect(AutoIncrementEntry("500", maximum: 2_147_483_647) == .value(500))
        #expect(AutoIncrementEntry(" 7 ", maximum: 2_147_483_647) == .value(7))
        #expect(AutoIncrementEntry("255", maximum: 255) == .value(255))
        #expect(AutoIncrementEntry("", maximum: 255) == .empty)
    }

    @Test("Zero, signs, separators and other text are refused", arguments: ["0", "-1", "+5", "1,000", "1.5", "abc"])
    func invalidCounter(text: String) {
        #expect(AutoIncrementEntry(text, maximum: 2_147_483_647) == .invalid(maximum: 2_147_483_647))
    }

    @Test("Past the column type's maximum the next INSERT fails, so the field refuses it")
    func counterPastTheType() {
        let entry = AutoIncrementEntry("128", maximum: AutoIncrementEntry.maximum(for: column("TINYINT")))
        #expect(entry == .invalid(maximum: 127))
        #expect(entry.message?.contains("127") == true)
        #expect(AutoIncrementEntry("2147483648", maximum: 2_147_483_647).message?.contains("2147483647") == true)
    }

    @Test("An exhausted TINYINT counter the server reports stands until the user types another")
    func untouchedCounterPastTheType() {
        #expect(AutoIncrementEntry("128", maximum: 127, original: 128) == .value(128))
        #expect(AutoIncrementEntry("129", maximum: 127, original: 128) == .invalid(maximum: 127))
    }

    // MARK: - Editability

    @Test("A save in progress holds the form")
    func savingHoldsTheForm() {
        let editability = StructureTableOptionsPolicy.resolve(hasBaseline: true, isReadOnly: false, isSaving: true)
        #expect(!editability.isEditable)
        #expect(editability.unavailableReason == StructureFooterPolicy.savingReason)
    }

    @Test("Nothing stages until the options are read")
    func noBaselineStagesNothing() {
        #expect(StructureTableOptionsPolicy.resolve(hasBaseline: false, isReadOnly: false, isSaving: false)
            == .init(isEditable: false, unavailableReason: nil))
    }

    @Test("Read-only Safe Mode shows the values and says why they cannot change")
    func readOnlySaysWhy() {
        let editability = StructureTableOptionsPolicy.resolve(hasBaseline: true, isReadOnly: true, isSaving: false)
        #expect(!editability.isEditable)
        #expect(editability.unavailableReason != nil)
        #expect(StructureTableOptionsPolicy.resolve(hasBaseline: true, isReadOnly: false, isSaving: false).isEditable)
    }
}
