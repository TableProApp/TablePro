//
//  StructureInspectorFormTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// The inspector's form for one definition, as the editor builds it and takes its edits back.
@MainActor
struct StructureInspectorFormTests {
    private func makeSession(
        type: DatabaseType = .mysql,
        objectKind: TableInfo.TableType = .table
    ) -> StructureEditingSession {
        let session = StructureEditingSession(
            identity: "test.users",
            connection: TestFixtures.makeConnection(database: "test", type: type),
            databaseName: "test",
            schemaName: nil,
            tableName: "users",
            objectKind: objectKind
        )
        session.changeManager.loadSchema(
            tableName: "users",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil),
                ColumnInfo(name: "email", dataType: "VARCHAR(255)", isNullable: true, isPrimaryKey: false,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        session.markBaselineAdopted()
        session.editor.refresh()
        return session
    }

    private func emailID(_ session: StructureEditingSession) throws -> UUID {
        try #require(session.changeManager.workingColumns.first { $0.name == "email" }).id
    }

    private func emailForm(_ session: StructureEditingSession) throws -> StructureInspectorForm {
        let id = try emailID(session)
        return try #require(session.editor.inspectorForm(for: .columns, id: id))
    }

    private func field(
        _ form: StructureInspectorForm,
        _ field: StructureColumnField
    ) throws -> StructureInspectorForm.Field {
        try #require(form.fields.first { $0.label == field.displayName })
    }

    private func commit(_ session: StructureEditingSession, _ field: StructureColumnField, _ value: String) throws {
        let form = try emailForm(session)
        let index = try self.field(form, field).id
        session.editor.commitInspectorField(section: .columns, id: form.entityID, field: index, value: value)
    }

    // MARK: - Content

    @Test("The form names the definition and lists the grid's own fields")
    func formDescribesTheDefinition() throws {
        let session = makeSession()
        let form = try emailForm(session)

        #expect(form.name == "email")
        #expect(form.section == .columns)
        #expect(form.isEditable)
        #expect(!form.isNew)
        #expect(!form.isDeleted)
        let labels = form.fields.map { $0.label }
        let headings = session.editor.adapter(for: .columns).provider.orderedColumnFields.map { $0.displayName }
        #expect(labels == headings)
        #expect(try field(form, .type).value == "VARCHAR(255)")
    }

    @Test("Each field gets the control its grid cell has")
    func controlsFollowTheGrid() throws {
        let form = try emailForm(makeSession())

        #expect(StructureInspectorControl.resolve(try field(form, .name)) == .text)
        #expect(StructureInspectorControl.resolve(try field(form, .type)) == .typePicker)
        #expect(StructureInspectorControl.resolve(try field(form, .nullable)) == .checkbox)
        #expect(StructureInspectorControl.resolve(try field(form, .comment)) == .multiline)
    }

    @Test("An edited field reads as modified and the others do not")
    func editedFieldIsModified() throws {
        let session = makeSession()
        var email = try #require(session.changeManager.workingColumns.first { $0.name == "email" })
        email.dataType = "TEXT"
        session.changeManager.updateColumn(id: email.id, with: email)

        let form = try emailForm(session)
        #expect(try field(form, .type).isModified)
        #expect(try !field(form, .name).isModified)
    }

    // MARK: - Read-only

    @Test("A definition marked for deletion is read-only")
    func deletedDefinitionIsReadOnly() throws {
        let session = makeSession()
        session.changeManager.deleteColumn(id: try emailID(session))

        let form = try emailForm(session)
        #expect(form.isDeleted)
        #expect(!form.isEditable)
        #expect(form.fields.allSatisfy { !$0.isEditable })
    }

    @Test("A save holding the edits makes the form read-only until it lets go")
    func heldSaveIsReadOnly() throws {
        let session = makeSession()
        let manager = session.changeManager
        var email = try #require(manager.workingColumns.first { $0.name == "email" })
        email.comment = "Contact"
        manager.updateColumn(id: email.id, with: email)

        let snapshot = try #require(manager.holdForSave())
        #expect(try !emailForm(session).isEditable)

        manager.releaseHold(snapshot, written: false)
        #expect(try emailForm(session).isEditable)
    }

    @Test("Safe Mode makes the form read-only")
    func safeModeIsReadOnly() throws {
        let session = makeSession()
        session.editor.isReadOnly = true

        let form = try emailForm(session)
        #expect(!form.isEditable)
        #expect(form.fields.allSatisfy { !$0.isEditable })
    }

    @Test("A materialized view locks the fields its grid locks")
    func materializedViewLocksFields() throws {
        let form = try emailForm(makeSession(type: .postgresql, objectKind: .materializedView))

        #expect(form.isEditable)
        #expect(try field(form, .name).isEditable)
        #expect(try field(form, .comment).isEditable)
        #expect(try !field(form, .type).isEditable)
        #expect(try !field(form, .nullable).isEditable)
        #expect(try !field(form, .defaultValue).isEditable)
    }

    // MARK: - Commits

    @Test("A commit stages one schema change on the definition")
    func commitStagesAChange() throws {
        let session = makeSession()
        try commit(session, .type, "TEXT")

        #expect(session.changeManager.hasChanges)
        #expect(session.changeManager.canUndo)
        #expect(session.changeManager.workingColumns[1].dataType == "TEXT")
    }

    @Test("A commit lands on the definition it names, whatever the filter shows")
    func commitFollowsIdentityUnderAFilter() throws {
        let session = makeSession()
        session.editor.searchText = "email"
        try commit(session, .name, "user_email")

        #expect(session.changeManager.workingColumns[0].name == "id")
        #expect(session.changeManager.workingColumns[1].name == "user_email")
    }

    @Test("The checkbox writes the value the grid's menu offers")
    func checkboxWritesTheGridValue() throws {
        let session = makeSession()
        try commit(session, .nullable, StructureRowProvider.booleanOptions[1])

        #expect(session.changeManager.workingColumns[1].isNullable == false)
    }

    @Test("A locked field refuses a commit from the inspector")
    func lockedFieldRefusesTheCommit() throws {
        let session = makeSession(type: .postgresql, objectKind: .materializedView)
        try commit(session, .type, "TEXT")
        try commit(session, .defaultValue, "'x'")

        #expect(!session.changeManager.hasChanges)
        #expect(session.changeManager.workingColumns[1].dataType == "VARCHAR(255)")
        #expect(session.changeManager.workingColumns[1].defaultValue == nil)
    }

    @Test("A commit refreshes the editor, so the form is read again")
    func commitBumpsTheRevision() throws {
        let session = makeSession()
        let revision = session.editor.revision
        try commit(session, .comment, "Contact")

        #expect(session.editor.revision != revision)
        #expect(try field(emailForm(session), .comment).value == "Contact")
    }

    // MARK: - Create Table

    @Test("A drafted table's new column is editable and takes a name")
    func createTableFormTakesEdits() throws {
        let manager = StructureChangeManager()
        manager.addNewColumn()
        let editor = StructureDefinitionEditor(
            manager: manager,
            context: .newTable(
                connection: TestFixtures.makeConnection(database: "test"),
                databaseName: "test",
                schemaName: nil
            )
        )
        let id = try #require(manager.workingColumns.first).id
        let form = try #require(editor.inspectorForm(for: .columns, id: id))
        #expect(form.isEditable)

        let name = try #require(form.fields.first { $0.label == StructureColumnField.name.displayName })
        editor.commitInspectorField(section: .columns, id: id, field: name.id, value: "sku")
        #expect(manager.workingColumns[0].name == "sku")
    }
}
