import Foundation
import TableProPluginKit
import Testing

struct PluginViewRowEditingTests {
    private let simpleOrigins = [
        PluginViewColumnOrigin(viewColumn: "id", baseColumn: "id"),
        PluginViewColumnOrigin(viewColumn: "name", baseColumn: "name"),
    ]

    @Test("An updatable view over one table is keyed on the view columns that show the table's key")
    func updatableViewIsEditable() {
        let editing = PluginViewRowEditing.resolve(
            isUpdatable: true, baseTableCount: 1, baseKeyColumns: ["id"], origins: simpleOrigins
        )
        #expect(editing == .editable(keyColumns: ["id"]))
    }

    @Test("A renamed key column keys the edit by its view name")
    func renamedKeyUsesViewName() {
        let origins = [
            PluginViewColumnOrigin(viewColumn: "order_id", baseColumn: "id"),
            PluginViewColumnOrigin(viewColumn: "line", baseColumn: "line_no"),
        ]
        let editing = PluginViewRowEditing.resolve(
            isUpdatable: true, baseTableCount: 1, baseKeyColumns: ["id", "line_no"], origins: origins
        )
        #expect(editing == .editable(keyColumns: ["order_id", "line"]))
        #expect(editing.keyColumns == ["order_id", "line"])
    }

    @Test("A view column named like the key but showing another column is not the key")
    func swappedNamesAreNotTheKey() {
        let origins = [
            PluginViewColumnOrigin(viewColumn: "id", baseColumn: "name"),
            PluginViewColumnOrigin(viewColumn: "name", baseColumn: "id"),
        ]
        let editing = PluginViewRowEditing.resolve(
            isUpdatable: true, baseTableCount: 1, baseKeyColumns: ["id"], origins: origins
        )
        #expect(editing == .editable(keyColumns: ["name"]))
    }

    @Test("The server's answer wins over everything else")
    func notUpdatableStaysReadOnly() {
        let editing = PluginViewRowEditing.resolve(
            isUpdatable: false, baseTableCount: 1, baseKeyColumns: ["id"], origins: simpleOrigins
        )
        #expect(editing == .readOnly(.notUpdatable))
        #expect(editing.keyColumns == nil)
    }

    @Test("A view with no column from any table is not updatable")
    func noBaseTableIsNotUpdatable() {
        let editing = PluginViewRowEditing.resolve(
            isUpdatable: true, baseTableCount: 0, baseKeyColumns: [], origins: []
        )
        #expect(editing == .readOnly(.notUpdatable))
    }

    @Test("A view that reads several tables stays read-only")
    func severalTablesStayReadOnly() {
        let editing = PluginViewRowEditing.resolve(
            isUpdatable: true, baseTableCount: 2, baseKeyColumns: ["id"], origins: simpleOrigins
        )
        #expect(editing == .readOnly(.readsSeveralTables))
    }

    @Test("A view over a table without a primary key stays read-only")
    func keylessTableStaysReadOnly() {
        let editing = PluginViewRowEditing.resolve(
            isUpdatable: true, baseTableCount: 1, baseKeyColumns: [], origins: simpleOrigins
        )
        #expect(editing == .readOnly(.baseTableHasNoKey))
    }

    @Test("A view missing one column of a composite key stays read-only")
    func partialKeyStaysReadOnly() {
        let editing = PluginViewRowEditing.resolve(
            isUpdatable: true, baseTableCount: 1, baseKeyColumns: ["id", "version"], origins: simpleOrigins
        )
        #expect(editing == .readOnly(.keyNotExposed))
    }
}
