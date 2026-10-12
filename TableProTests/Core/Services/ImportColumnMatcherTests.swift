//
//  ImportColumnMatcherTests.swift
//  TableProTests
//

@testable import TablePro
import Testing

struct ImportColumnMatcherTests {
    private let columns = ["id", "full_name", "email"]

    private func mapped(_ choices: [ImportFieldChoice]) -> [String?] {
        choices.map(\.mappedColumn)
    }

    @Test("A name match ignores case and leaves an unmatched field skipped")
    func nameMatchIgnoresCase() {
        let choices = ImportColumnMatcher.byName(fields: ["ID", "Name", "E-mail"], columns: columns)

        #expect(mapped(choices) == ["id", nil, nil])
        #expect(choices[1] == .skipped)
    }

    @Test("Two fields that fold to one column do not both claim it")
    func nameMatchClaimsEachColumnOnce() {
        let choices = ImportColumnMatcher.byName(fields: ["email", "EMAIL"], columns: columns)

        #expect(mapped(choices) == ["email", nil])
    }

    @Test("An exact spelling wins over a case-insensitive one when the table holds both")
    func exactSpellingWinsACaseCollision() {
        let choices = ImportColumnMatcher.byName(fields: ["name", "Name"], columns: ["Name", "name"])

        #expect(mapped(choices) == ["name", "Name"])
    }

    @Test("A field spelled exactly like the column wins it over an earlier field that differs only by case")
    func exactSpellingWinsAcrossFields() {
        let choices = ImportColumnMatcher.byName(fields: ["Email", "email"], columns: columns)

        #expect(mapped(choices) == [nil, "email"])
    }

    @Test("Position pairs field i with column i and skips the fields past the last column")
    func positionPairsInOrder() {
        let choices = ImportColumnMatcher.byPosition(
            fields: ["Column 1", "Column 2", "Column 3", "Column 4"],
            columns: columns
        )

        #expect(mapped(choices) == ["id", "full_name", "email", nil])
    }

    @Test("A file shorter than the table leaves the trailing columns unmapped")
    func positionWithFewerFields() {
        let choices = ImportColumnMatcher.byPosition(fields: ["a", "b"], columns: columns)

        #expect(mapped(choices) == ["id", "full_name"])
    }

    @Test("A remembered column is applied where the name match finds nothing")
    func overrideAppliesToUnmatchedField() {
        let choices = ImportColumnMatcher.applying(
            ["Name": .column("full_name"), "E-mail": .column("email")],
            fields: ["id", "Name", "E-mail"],
            columns: columns
        )

        #expect(mapped(choices) == ["id", "full_name", "email"])
    }

    @Test("A remembered skip wins over a field whose name matches a column")
    func rememberedSkipBeatsNameMatch() {
        let choices = ImportColumnMatcher.applying(["id": .skip], fields: ["id", "email"], columns: columns)

        #expect(mapped(choices) == [nil, "email"])
        #expect(choices[0].include == false)
    }

    @Test("A remembered column the table no longer has falls back to the name match")
    func droppedColumnFallsBackToNameMatch() {
        let choices = ImportColumnMatcher.applying(
            ["email": .column("contact_email")],
            fields: ["email"],
            columns: columns
        )

        #expect(mapped(choices) == ["email"])
    }

    @Test("A remembered column resolves to the table's current spelling")
    func overrideResolvesColumnCase() {
        let choices = ImportColumnMatcher.applying(["Name": .column("FULL_NAME")], fields: ["Name"], columns: columns)

        #expect(mapped(choices) == ["full_name"])
    }

    @Test("A remembered field is found when the file spells its header in another case")
    func overrideFieldLookupIgnoresCase() {
        let choices = ImportColumnMatcher.applying(["name": .column("full_name")], fields: ["NAME"], columns: columns)

        #expect(mapped(choices) == ["full_name"])
    }

    @Test("Two remembered entries that differ only by case say nothing about a third spelling")
    func ambiguousCaseVariantsAreIgnored() {
        let choices = ImportColumnMatcher.applying(
            ["Email": .skip, "email": .column("email")],
            fields: ["EMAIL"],
            columns: columns
        )

        #expect(mapped(choices) == ["email"])
    }

    @Test("A remembered column takes precedence over a name match that would claim it first")
    func overrideClaimsBeforeNameMatch() {
        let choices = ImportColumnMatcher.applying(
            ["contact": .column("email")],
            fields: ["email", "contact"],
            columns: columns
        )

        #expect(mapped(choices) == [nil, "email"])
    }

    @Test("A choice switched off keeps its column without claiming it")
    func excludedChoiceClaimsNothing() {
        let choices = ImportColumnMatcher.resolve(
            fields: ["email", "work_email"],
            columns: columns,
            preferring: [[
                "email": ImportFieldChoice(include: false, column: "email"),
                "work_email": ImportFieldChoice(include: true, column: "email")
            ]]
        )

        #expect(choices[0] == ImportFieldChoice(include: false, column: "email"))
        #expect(choices[1] == ImportFieldChoice(include: true, column: "email"))
    }

    @Test("A higher tier wins its column over a lower tier's choice for a field listed earlier")
    func higherTierWinsAcrossFields() {
        let choices = ImportColumnMatcher.resolve(
            fields: ["legacy_email", "Column 2"],
            columns: columns,
            preferring: [
                ["Column 2": ImportFieldChoice(include: true, column: "email")],
                ["legacy_email": ImportFieldChoice(include: true, column: "email")]
            ]
        )

        #expect(mapped(choices) == [nil, "email"])
    }

    @Test("A skip saved for one of two fields that differ only by case leaves the other to the name match")
    func savedSkipStaysWithItsOwnSpelling() {
        let choices = ImportColumnMatcher.applying(["Email": .skip], fields: ["Email", "email"], columns: columns)

        #expect(mapped(choices) == [nil, "email"])
    }

    @Test("Merging keeps a case variant that belongs to another layout's field")
    func mergeKeepsAnotherLayoutsCaseVariant() {
        let merged = ImportColumnMatcher.merging(
            [:],
            forFields: ["Email"],
            into: ["Email": .column("work_email"), "email": .column("home_email")]
        )

        #expect(merged == ["email": .column("home_email")])
    }

    @Test("Only departures from the name match are worth remembering")
    func overridesKeepOnlyDepartures() {
        let fields = ["id", "Name", "email", "notes"]
        let choices = [
            ImportFieldChoice(include: true, column: "id"),
            ImportFieldChoice(include: true, column: "full_name"),
            ImportFieldChoice(include: false, column: "email"),
            ImportFieldChoice.skipped
        ]

        let overrides = ImportColumnMatcher.overrides(fields: fields, columns: columns, choices: choices)

        #expect(overrides == ["Name": .column("full_name"), "email": .skip])
    }

    @Test("A field left unmatched stores nothing, so a column added later is picked up by name")
    func unmatchedFieldStoresNothing() {
        let overrides = ImportColumnMatcher.overrides(fields: ["notes"], columns: columns, choices: [.skipped])
        let later = ImportColumnMatcher.applying(overrides, fields: ["notes"], columns: columns + ["notes"])

        #expect(overrides.isEmpty)
        #expect(mapped(later) == ["notes"])
    }

    @Test("Merging keeps the entries of fields this file does not hold")
    func mergeKeepsOtherLayouts() {
        let merged = ImportColumnMatcher.merging(
            ["Name": .column("full_name")],
            forFields: ["Name", "email"],
            into: ["Customer": .column("full_name"), "email": .skip]
        )

        #expect(merged == ["Customer": .column("full_name"), "Name": .column("full_name")])
    }

    @Test("Merging replaces an entry whose name differs from a field of this file only by case")
    func mergeReplacesCaseVariant() {
        let merged = ImportColumnMatcher.merging(
            ["Email": .column("email")],
            forFields: ["Email"],
            into: ["EMAIL": .skip]
        )

        #expect(merged == ["Email": .column("email")])
    }

    @Test("A field restored from a remembered choice is reported, a plain name match is not")
    func restoredFieldsNameOnlyTheOverrides() {
        let overrides: [String: ImportMappingOverride] = ["Name": .column("full_name"), "id": .column("id")]
        let fields = ["id", "Name"]
        let choices = ImportColumnMatcher.applying(overrides, fields: fields, columns: columns)

        let restored = ImportColumnMatcher.restoredFields(overrides, fields: fields, columns: columns, choices: choices)

        #expect(restored == ["Name"])
    }

    @Test("A restored field that the user changes again is no longer reported")
    func restoredFieldsFollowTheCurrentChoice() {
        let overrides: [String: ImportMappingOverride] = ["Name": .column("full_name")]
        let fields = ["Name"]

        let restored = ImportColumnMatcher.restoredFields(
            overrides, fields: fields, columns: columns, choices: [.skipped]
        )

        #expect(restored.isEmpty)
    }
}
