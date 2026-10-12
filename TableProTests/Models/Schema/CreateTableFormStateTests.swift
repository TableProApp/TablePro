//
//  CreateTableFormStateTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private enum FormFixture {
    static let keyTypes: PluginFormField.Kind = .picker(
        options: [PluginFormOption(value: "S", label: "String"), PluginFormOption(value: "N", label: "Number")],
        defaultValue: "S"
    )

    static let spec = PluginCreateTableFormSpec(
        sections: [
            PluginFormSection(id: "keys", title: "Primary Key", fields: [
                PluginFormField(id: "pk", label: "Partition key", kind: .text(placeholder: "pk", isRequired: true)),
                PluginFormField(id: "pkType", label: "Type", kind: keyTypes),
                PluginFormField(id: "sk", label: "Sort key", kind: .text(placeholder: nil, isRequired: false)),
                PluginFormField(
                    id: "skType", label: "Type", kind: keyTypes,
                    visibleWhen: PluginFormCondition(fieldId: "sk", values: nil)
                )
            ]),
            PluginFormSection(id: "capacity", title: "Capacity", fields: [
                PluginFormField(
                    id: "billing", label: "Billing",
                    kind: .picker(options: [
                        PluginFormOption(value: "PAY_PER_REQUEST", label: "On-demand"),
                        PluginFormOption(value: "PROVISIONED", label: "Provisioned")
                    ], defaultValue: "PAY_PER_REQUEST")
                ),
                PluginFormField(
                    id: "read", label: "Read capacity",
                    kind: .integer(defaultValue: 5, minimum: 1, maximum: 100),
                    visibleWhen: PluginFormCondition(fieldId: "billing", values: ["PROVISIONED"])
                ),
                PluginFormField(id: "protect", label: "Deletion protection", kind: .toggle(defaultValue: false))
            ]),
            PluginFormSection(
                id: "indexes", title: "Indexes",
                fields: [
                    PluginFormField(id: "name", label: "Index name", kind: .text(placeholder: nil, isRequired: true)),
                    PluginFormField(
                        id: "projection", label: "Attributes",
                        kind: .picker(options: [
                            PluginFormOption(value: "ALL", label: "All"),
                            PluginFormOption(value: "INCLUDE", label: "Chosen")
                        ], defaultValue: "ALL")
                    ),
                    PluginFormField(
                        id: "included", label: "Chosen attributes",
                        kind: .text(placeholder: nil, isRequired: true),
                        visibleWhen: PluginFormCondition(fieldId: "projection", values: ["INCLUDE"])
                    )
                ],
                isRepeating: true, addLabel: "Add Index", maximumCount: 2
            )
        ],
        footnote: "Only key attributes are declared."
    )

    static func field(_ id: String, in sectionId: String) -> PluginFormField? {
        spec.sections.first { $0.id == sectionId }?.fields.first { $0.id == id }
    }
}

struct CreateTableFormStateTests {
    private func index(_ entryId: UUID) -> CreateTableFormState.Location {
        .entry(sectionId: "indexes", entryId: entryId)
    }

    private func addIndex(to state: inout CreateTableFormState) throws -> UUID {
        let added = state.addEntry(to: "indexes")
        return try #require(added)
    }

    @Test("Top-level values are seeded from each field's initial value")
    func seedsTopLevelValues() {
        let state = CreateTableFormState(spec: FormFixture.spec)

        #expect(state.values == [
            "pk": "", "pkType": "S", "sk": "", "skType": "S",
            "billing": "PAY_PER_REQUEST", "read": "5", "protect": "false"
        ])
        #expect(state.entries(in: "indexes").isEmpty)
        #expect(!state.holdsWork)
    }

    @Test("A new entry is seeded with the repeating section's initial values")
    func addEntrySeedsInitialValues() throws {
        var state = CreateTableFormState(spec: FormFixture.spec)

        let entryId = try addIndex(to: &state)

        #expect(state.entries(in: "indexes").count == 1)
        #expect(state.value(of: "projection", at: index(entryId)) == "ALL")
        #expect(state.value(of: "name", at: index(entryId)) == "")
        #expect(state.value(of: "included", at: index(entryId)) == "")
    }

    @Test("Adding stops at the section's maximum count")
    func addEntryRespectsMaximumCount() {
        var state = CreateTableFormState(spec: FormFixture.spec)

        let first = state.addEntry(to: "indexes")
        let second = state.addEntry(to: "indexes")
        let canAddThird = state.canAddEntry(to: "indexes")
        let third = state.addEntry(to: "indexes")

        #expect(first != nil)
        #expect(second != nil)
        #expect(!canAddThird)
        #expect(third == nil)
        #expect(state.entries(in: "indexes").count == 2)
    }

    @Test("A section that does not repeat takes no entries")
    func nonRepeatingSectionTakesNoEntries() {
        var state = CreateTableFormState(spec: FormFixture.spec)

        let keys = state.addEntry(to: "keys")
        let missing = state.addEntry(to: "missing")

        #expect(!state.canAddEntry(to: "keys"))
        #expect(keys == nil)
        #expect(missing == nil)
    }

    @Test("Removing an entry keeps the others and frees a slot")
    func removeEntryKeepsTheRest() throws {
        var state = CreateTableFormState(spec: FormFixture.spec)
        let first = try addIndex(to: &state)
        let second = try addIndex(to: &state)
        state.setValue("by_second", of: "name", at: index(second))

        state.removeEntry(first, from: "indexes")

        #expect(state.entries(in: "indexes").count == 1)
        #expect(state.value(of: "name", at: index(second)) == "by_second")
        #expect(state.canAddEntry(to: "indexes"))
    }

    @Test("A condition with no values shows the field once the other field is not blank")
    func conditionWithoutValuesFollowsNonEmpty() throws {
        var state = CreateTableFormState(spec: FormFixture.spec)
        let sortKeyType = try #require(FormFixture.field("skType", in: "keys"))

        #expect(!state.isVisible(sortKeyType, at: .topLevel))

        state.setValue("   ", of: "sk", at: .topLevel)
        #expect(!state.isVisible(sortKeyType, at: .topLevel))

        state.setValue("created_at", of: "sk", at: .topLevel)
        #expect(state.isVisible(sortKeyType, at: .topLevel))
    }

    @Test("A condition with values shows the field only for those values")
    func conditionWithValuesMatchesThem() throws {
        var state = CreateTableFormState(spec: FormFixture.spec)
        let read = try #require(FormFixture.field("read", in: "capacity"))

        #expect(!state.isVisible(read, at: .topLevel))

        state.setValue("PROVISIONED", of: "billing", at: .topLevel)
        #expect(state.isVisible(read, at: .topLevel))
    }

    @Test("A field in a repeating section follows its own entry, not its siblings or the top level")
    func repeatingConditionIsScopedToItsEntry() throws {
        var state = CreateTableFormState(spec: FormFixture.spec)
        let included = try #require(FormFixture.field("included", in: "indexes"))
        let chosen = try addIndex(to: &state)
        let all = try addIndex(to: &state)

        state.setValue("INCLUDE", of: "projection", at: index(chosen))
        state.setValue("INCLUDE", of: "projection", at: .topLevel)

        #expect(state.isVisible(included, at: index(chosen)))
        #expect(!state.isVisible(included, at: index(all)))
    }

    @Test("A field whose controlling field is hidden is hidden too")
    func visibilityFollowsTheControllingField() throws {
        let spec = PluginCreateTableFormSpec(sections: [
            PluginFormSection(id: "main", title: nil, fields: [
                PluginFormField(id: "mode", label: "Mode", kind: .text(placeholder: nil, isRequired: false)),
                PluginFormField(
                    id: "detail", label: "Detail", kind: .text(placeholder: nil, isRequired: false),
                    visibleWhen: PluginFormCondition(fieldId: "mode", values: nil)
                ),
                PluginFormField(
                    id: "note", label: "Note", kind: .text(placeholder: nil, isRequired: true),
                    visibleWhen: PluginFormCondition(fieldId: "detail", values: ["x"])
                )
            ])
        ])
        var state = CreateTableFormState(spec: spec)
        let note = try #require(spec.sections.first?.fields.last)

        state.setValue("x", of: "detail", at: .topLevel)
        #expect(!state.isVisible(note, at: .topLevel))
        #expect(state.fieldIssues().isEmpty)

        state.setValue("on", of: "mode", at: .topLevel)
        #expect(state.isVisible(note, at: .topLevel))
    }

    @Test("A blank table name is an issue")
    func blankTableNameIsAnIssue() {
        var state = CreateTableFormState(spec: FormFixture.spec)
        state.setValue("id", of: "pk", at: .topLevel)

        let issues = state.issues(tableName: "   ")

        #expect(issues.count == 1)
        #expect(issues.first?.location == nil)
        #expect(issues.first?.kind == .missing)
        #expect(state.issues(tableName: "orders").isEmpty)
    }

    @Test("A required text field that is empty is an issue until it is filled")
    func requiredTopLevelFieldIsAnIssue() {
        var state = CreateTableFormState(spec: FormFixture.spec)

        let issues = state.issues(tableName: "orders")
        #expect(issues.count == 1)
        #expect(issues.first?.fieldId == "pk")
        #expect(issues.first?.location == .topLevel)
        #expect(issues.first?.kind == .missing)

        state.setValue("id", of: "pk", at: .topLevel)
        #expect(state.issues(tableName: "orders").isEmpty)
    }

    @Test("A hidden required field is never an issue")
    func hiddenRequiredFieldIsIgnored() throws {
        var state = CreateTableFormState(spec: FormFixture.spec)
        state.setValue("id", of: "pk", at: .topLevel)
        let entryId = try addIndex(to: &state)
        state.setValue("by_status", of: "name", at: index(entryId))

        #expect(state.issues(tableName: "orders").isEmpty)

        state.setValue("INCLUDE", of: "projection", at: index(entryId))
        let issues = state.issues(tableName: "orders")
        #expect(issues.count == 1)
        #expect(issues.first?.fieldId == "included")
        #expect(issues.first?.location == index(entryId))
        #expect(issues.first?.qualifiedMessage.contains("Indexes") == true)
    }

    @Test("An integer field is checked only while it is visible, and against its bounds")
    func integerValidationRespectsVisibilityAndBounds() {
        var state = CreateTableFormState(spec: FormFixture.spec)
        state.setValue("id", of: "pk", at: .topLevel)
        state.setValue("many", of: "read", at: .topLevel)

        #expect(state.issues(tableName: "orders").isEmpty)

        state.setValue("PROVISIONED", of: "billing", at: .topLevel)
        let cases: [(value: String, isValid: Bool)] = [
            ("many", false), ("0", false), ("101", false), ("1", true), ("100", true), (" 50 ", true), ("", true)
        ]
        for testCase in cases {
            state.setValue(testCase.value, of: "read", at: .topLevel)
            let issues = state.issues(tableName: "orders")
            #expect(issues.isEmpty == testCase.isValid, "read = \(testCase.value)")
            if !testCase.isValid {
                #expect(issues.first?.kind == .invalid, "read = \(testCase.value)")
                #expect(state.inlineMessage(for: "read", at: .topLevel) != nil, "read = \(testCase.value)")
            }
        }
    }

    @Test("The request carries visible values only and trims the table name")
    func requestOmitsHiddenFields() throws {
        var state = CreateTableFormState(spec: FormFixture.spec)
        state.setValue("id", of: "pk", at: .topLevel)
        state.setValue("250", of: "read", at: .topLevel)
        let all = try addIndex(to: &state)
        state.setValue("by_status", of: "name", at: index(all))
        state.setValue("left over", of: "included", at: index(all))
        let chosen = try addIndex(to: &state)
        state.setValue("by_date", of: "name", at: index(chosen))
        state.setValue("INCLUDE", of: "projection", at: index(chosen))
        state.setValue("total, status", of: "included", at: index(chosen))

        let request = state.request(tableName: "  orders ")

        #expect(request.tableName == "orders")
        #expect(request.values == [
            "pk": "id", "pkType": "S", "sk": "", "billing": "PAY_PER_REQUEST", "protect": "false"
        ])
        #expect(request.repeatedValues["indexes"] == [
            ["name": "by_status", "projection": "ALL"],
            ["name": "by_date", "projection": "INCLUDE", "included": "total, status"]
        ])
    }

    @Test("A repeating section with no entries is sent as an empty list")
    func emptyRepeatingSectionIsAnEmptyList() {
        let request = CreateTableFormState(spec: FormFixture.spec).request(tableName: "orders")

        #expect(request.repeatedValues["indexes"]?.isEmpty == true)
    }

    @Test("A driver error sits beside its field only when the field id is unambiguous and visible")
    func submissionErrorPlacement() throws {
        var state = CreateTableFormState(spec: FormFixture.spec)
        state.setValue("PROVISIONED", of: "billing", at: .topLevel)

        state.recordSubmissionError(PluginCreateTableFormError(message: "Too low", fieldId: "read"))
        #expect(state.inlineSubmissionErrorFieldId == "read")
        #expect(state.inlineMessage(for: "read", at: .topLevel) == "Too low")

        state.recordSubmissionError(PluginCreateTableFormError(message: "Bad index", fieldId: "name"))
        #expect(state.inlineSubmissionErrorFieldId == nil)

        state.recordSubmissionError(PluginCreateTableFormError(message: "Bad name", fieldId: nil))
        #expect(state.inlineSubmissionErrorFieldId == nil)

        state.setValue("PAY_PER_REQUEST", of: "billing", at: .topLevel)
        #expect(state.submissionError == nil)
    }

    @Test("Any edit clears the driver's last error")
    func editsClearTheSubmissionError() throws {
        var state = CreateTableFormState(spec: FormFixture.spec)
        let error = PluginCreateTableFormError(message: "Nope")

        state.recordSubmissionError(error)
        state.setValue("id", of: "pk", at: .topLevel)
        #expect(state.submissionError == nil)

        state.recordSubmissionError(error)
        let entryId = try addIndex(to: &state)
        #expect(state.submissionError == nil)

        state.recordSubmissionError(error)
        state.removeEntry(entryId, from: "indexes")
        #expect(state.submissionError == nil)

        state.recordSubmissionError(error)
        state.setValue("id", of: "pk", at: .topLevel)
        #expect(state.submissionError == error)
    }

    @Test("The form holds work once a value leaves its default or an entry exists")
    func holdsWorkTracksEdits() throws {
        var state = CreateTableFormState(spec: FormFixture.spec)

        state.setValue("true", of: "protect", at: .topLevel)
        #expect(state.holdsWork)

        state.setValue("false", of: "protect", at: .topLevel)
        #expect(!state.holdsWork)

        let entryId = try addIndex(to: &state)
        #expect(state.holdsWork)

        state.removeEntry(entryId, from: "indexes")
        #expect(!state.holdsWork)
    }

    @Test("The preview names the first issue before it asks the driver")
    func previewPrefersLocalIssues() {
        let state = CreateTableFormState(spec: FormFixture.spec)
        var asked = false

        let preview = state.preview(tableName: "orders") { _ in
            asked = true
            return ["CreateTable {}"]
        }

        #expect(!asked)
        guard case .message = preview else {
            Issue.record("Expected a message, got \(preview)")
            return
        }
    }

    @Test("The preview shows the driver's statements, or the driver's own error")
    func previewShowsStatementsOrDriverError() {
        var state = CreateTableFormState(spec: FormFixture.spec)
        state.setValue("id", of: "pk", at: .topLevel)

        let statements = state.preview(tableName: "orders") { request in
            ["CreateTable \(request.tableName)", "Second;"]
        }
        #expect(statements == .statements("CreateTable orders;\n\nSecond;"))

        let refused = state.preview(tableName: "orders") { _ in
            throw PluginCreateTableFormError(message: "Name the key", fieldId: "pk")
        }
        #expect(refused == .message("Name the key"))

        let empty = state.preview(tableName: "orders") { _ in [] }
        guard case .message = empty else {
            Issue.record("An empty statement list must not preview as statements")
            return
        }
    }
}

@MainActor
struct CreateTableDraftFormTests {
    @Test("A draft resolves its form once and keeps it")
    func resolvesFormOnce() {
        let draft = CreateTableDraft()
        #expect(!draft.hasResolvedForm)

        draft.resolveForm(from: FormFixture.spec)
        #expect(draft.hasResolvedForm)
        #expect(draft.form?.spec == FormFixture.spec)

        draft.form?.setValue("id", of: "pk", at: .topLevel)
        draft.resolveForm(from: nil)
        #expect(draft.form?.value(of: "pk", at: .topLevel) == "id")
    }

    @Test("Renaming the table clears what the driver said about the last attempt")
    func renameClearsSubmissionError() {
        let draft = CreateTableDraft()
        draft.resolveForm(from: FormFixture.spec)
        draft.tableName = "a"
        draft.form?.recordSubmissionError(PluginCreateTableFormError(message: "A table name is too short"))

        draft.tableName = "a"
        #expect(draft.form?.submissionError != nil)

        draft.tableName = "orders"
        #expect(draft.form?.submissionError == nil)
    }

    @Test("A driver without a form leaves the draft on the column grid")
    func noSpecMeansGrid() {
        let draft = CreateTableDraft()

        draft.resolveForm(from: nil)

        #expect(draft.hasResolvedForm)
        #expect(draft.form == nil)
    }

    @Test("An edited form counts as work worth protecting")
    func editedFormHoldsWork() {
        let draft = CreateTableDraft()
        draft.resolveForm(from: FormFixture.spec)
        #expect(!draft.holdsWork)

        draft.form?.setValue("id", of: "pk", at: .topLevel)
        #expect(draft.holdsWork)
    }
}
