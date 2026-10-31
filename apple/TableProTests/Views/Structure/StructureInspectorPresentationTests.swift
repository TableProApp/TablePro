//
//  StructureInspectorPresentationTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct StructureInspectorPresentationTests {
    private func field(
        _ kind: StructureInspectorForm.Field.Kind,
        value: String? = "x",
        isEditable: Bool = true
    ) -> StructureInspectorForm.Field {
        StructureInspectorForm.Field(id: 0, label: "Field", value: value, kind: kind, isModified: false, isEditable: isEditable)
    }

    // MARK: - Subject

    @Test("A selected index is named as an index of its table")
    func entitySubjectNamesItsKind() {
        let subject = StructureInspectorPresentation.subject(
            for: .entity(.indexes, UUID()),
            definitionName: "idx_email",
            tableName: "users"
        )
        #expect(subject == .definition(name: "idx_email", section: .indexes, table: "users"))
        #expect(subject.subtitle == String(format: String(localized: "Index of %@"), "users"))
    }

    @Test("An unnamed definition in a table not yet named reads as new, with no table")
    func newDefinitionInNewTable() {
        let subject = StructureInspectorPresentation.subject(
            for: .entity(.columns, UUID()),
            definitionName: "",
            tableName: ""
        )
        #expect(subject.title == String(localized: "New Column"))
        #expect(subject.subtitle == String(localized: "Column"))
    }

    @Test("Nothing selected, or several, names the table")
    func tableSubject() {
        #expect(StructureInspectorPresentation.subject(for: .table, definitionName: nil, tableName: "users")
            == .tableOnly(table: "users"))
        #expect(StructureInspectorPresentation.subject(for: .several(.columns, 3), definitionName: nil, tableName: "users")
            == .tableOnly(table: "users"))
    }

    @Test("A table Create Table has not named yet reads as a new table")
    func unnamedTable() {
        let subject = StructureInspectorPresentation.subject(for: .table, definitionName: nil, tableName: "")
        #expect(subject.title == String(localized: "New Table"))
    }

    @Test("Several selected say how many of which kind")
    func severalTitle() {
        #expect(StructureInspectorPresentation.severalTitle(.columns, count: 3)
            == String(format: String(localized: "%d Columns Selected"), 3))
        #expect(StructureInspectorPresentation.severalTitle(.foreignKeys, count: 2)
            == String(format: String(localized: "%d Foreign Keys Selected"), 2))
        #expect(StructureInspectorPresentation.severalTitle(.checkConstraints, count: 4).contains("4"))
    }

    @Test("Each control is identified by its section and field index")
    func controlIdentifier() {
        #expect(StructureInspectorPresentation.controlIdentifier(section: .foreignKeys, field: 3)
            == "structure-inspector-foreignKeys-3")
    }

    // MARK: - Controls

    @Test("Each editable field kind gets its control")
    func editableControls() {
        #expect(StructureInspectorControl.resolve(field(.text)) == .text)
        #expect(StructureInspectorControl.resolve(field(.multiline)) == .multiline)
        #expect(StructureInspectorControl.resolve(field(.toggle, value: "YES")) == .checkbox)
        #expect(StructureInspectorControl.resolve(field(.typePicker)) == .typePicker)

        let menu = [GridMenuOption.value(title: "BTREE", sql: "BTREE"), .value(title: "HASH", sql: "HASH")]
        guard case .popUp(let choices) = StructureInspectorControl.resolve(field(.menu(menu), value: "HASH")) else {
            Issue.record("A menu field is a pop-up button")
            return
        }
        #expect(choices.selectedTitle == "HASH")

        let combo = [GridMenuOption.value(title: "NULL", sql: "NULL"), .custom(title: "Custom…")]
        guard case .comboBox = StructureInspectorControl.resolve(field(.combo(combo), value: "0")) else {
            Issue.record("A combo field is a combo box")
            return
        }
    }

    @Test("A field the form cannot edit is plain text, whatever its kind")
    func readOnlyControls() {
        #expect(StructureInspectorControl.resolve(field(.text, value: "email", isEditable: false)) == .readOnly("email"))
        #expect(StructureInspectorControl.resolve(field(.toggle, value: "NO", isEditable: false)) == .readOnly("NO"))
        #expect(StructureInspectorControl.resolve(field(.typePicker, value: nil, isEditable: false)) == .readOnly(""))
        #expect(StructureInspectorControl.resolve(field(.combo([]), value: "''", isEditable: false)) == .readOnly("''"))
    }

    @Test("A read-only menu field shows the title the menu gives its value")
    func readOnlyMenuShowsTitle() {
        let options = [GridMenuOption.value(title: "Empty string", sql: "''")]
        #expect(StructureInspectorControl.resolve(field(.menu(options), value: "''", isEditable: false))
            == .readOnly("Empty string"))
    }

    // MARK: - Choices

    @Test("The item whose SQL the field holds is selected, and picking an item writes its SQL")
    func selectsBySQL() throws {
        let choices = StructureInspectorChoices(
            options: [.value(title: "Empty string", sql: "''"), .value(title: "NULL", sql: "NULL")],
            current: "''"
        )
        #expect(choices.selectedTitle == "Empty string")
        let null = try #require(choices.items.first { $0.title == "NULL" })
        #expect(choices.value(of: null.id) == "NULL")
    }

    @Test("A value the menu does not list is kept as the first item and selected")
    func keepsUnlistedValue() {
        let choices = StructureInspectorChoices(options: GridMenuOption.values(["utf8mb4", "latin1"]), current: "utf8")
        #expect(choices.items.first?.title == "utf8")
        #expect(choices.selectedTitle == "utf8")
        #expect(choices.items.count == 3)
    }

    @Test("A value that differs only in case selects the listed item rather than adding one")
    func matchesCaseInsensitively() {
        let choices = StructureInspectorChoices(options: GridMenuOption.values(["utf8mb4"]), current: "UTF8MB4")
        #expect(choices.items.count == 1)
        #expect(choices.selectedTitle == "utf8mb4")
    }

    @Test("An empty value selects the item that clears, and nothing when there is none")
    func emptyValue() {
        let clearing = StructureInspectorChoices(
            options: [.clear(title: "No Default"), .value(title: "NULL", sql: "NULL")],
            current: ""
        )
        #expect(clearing.selectedTitle == "No Default")

        let plain = StructureInspectorChoices(options: GridMenuOption.values(["CASCADE", "RESTRICT"]), current: "")
        #expect(plain.selectedID == nil)
        #expect(plain.items.count == 2)
    }

    @Test("A section header starts a group and the custom entry is left to free text")
    func groupsAndCustom() {
        let choices = StructureInspectorChoices(
            options: [
                .value(title: "NULL", sql: "NULL"),
                .sectionHeader("Functions"),
                .value(title: "CURRENT_TIMESTAMP", sql: "CURRENT_TIMESTAMP"),
                .custom(title: "Custom…"),
            ],
            current: "NULL"
        )
        #expect(choices.groups.map { $0.header } == [nil, "Functions"])
        #expect(choices.groups.map { group in group.items.map { $0.title } } == [["NULL"], ["CURRENT_TIMESTAMP"]])
        #expect(!choices.items.contains { $0.title == "Custom…" })
    }

    @Test("A header with nothing under it still shows, since it reports the menu's state")
    func lonelyHeaderStays() {
        let choices = StructureInspectorChoices(options: [.sectionHeader("Loading…")], current: "")
        #expect(choices.groups.map { $0.header } == ["Loading…"])
    }
}
