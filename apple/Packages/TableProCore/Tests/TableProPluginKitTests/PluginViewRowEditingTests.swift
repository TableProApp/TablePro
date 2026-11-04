import Foundation
import TableProPluginKit
import Testing

struct PluginViewRowEditingTests {
    private let table = PluginViewBaseTable(schema: "public", name: "t")

    private func column(_ name: String, _ base: String?, writable: Bool = true) -> PluginViewColumn {
        PluginViewColumn(name: name, baseColumn: base, acceptsWrites: writable)
    }

    private func base(
        _ name: String,
        nullable: Bool = true,
        defaultValue: String? = nil,
        assigns: Bool = false,
        writable: Bool = true
    ) -> PluginViewBaseColumn {
        PluginViewBaseColumn(
            name: name, isNullable: nullable, defaultValue: defaultValue, assignsValue: assigns, acceptsWrites: writable
        )
    }

    private func resolve(
        operations: PluginViewWriteOperations = .all,
        columns: [PluginViewColumn],
        keys: [String]? = ["id"],
        baseColumns: [PluginViewBaseColumn]? = nil
    ) -> PluginViewRowEditing {
        PluginViewRowEditing.resolve(
            operations: operations, baseTable: table, columns: columns, baseKeyColumns: keys, baseColumns: baseColumns
        )
    }

    @Test("A view over one table that shows its key is keyed on the view columns showing it")
    func renamedKeyUsesViewNames() throws {
        let answer = resolve(
            columns: [column("order_id", "id"), column("line", "line_no"), column("label", "name")],
            keys: ["id", "line_no"],
            baseColumns: [base("id", nullable: false), base("line_no", nullable: false), base("name")]
        )
        let target = try #require(answer.writeTarget)
        #expect(target.keyColumns == ["order_id", "line"])
        #expect(target.baseKeyColumns == ["id", "line_no"])
        #expect(target.baseColumnNames == ["order_id": "id", "line": "line_no", "label": "name"])
        #expect(target.operations == .all)
        #expect(target.readOnlyColumns.isEmpty)
    }

    @Test("A view column named like the key but showing another column is not the key")
    func swappedNamesAreNotTheKey() {
        let answer = resolve(columns: [column("id", "name"), column("name", "code")])
        #expect(answer == .readOnly(.keyNotExposed))
    }

    @Test("Without UPDATE the view is not updatable, whatever else the server allows")
    func updateIsRequired() {
        #expect(resolve(operations: [.insert, .delete], columns: [column("id", "id")]) == .readOnly(.notUpdatable))
    }

    @Test("A key the user cannot read hides the table, an empty one means it has no key")
    func baseKeyReasons() {
        #expect(resolve(columns: [column("id", "id")], keys: nil) == .readOnly(.baseTableHidden))
        #expect(resolve(columns: [column("id", "id")], keys: []) == .readOnly(.baseTableHasNoKey))
    }

    @Test("Computed, server-refused and server-owned columns are read-only")
    func readOnlyColumns() throws {
        let answer = resolve(
            columns: [
                column("id", "id"), column("q2", nil, writable: false), column("gen", "gen"),
                column("ident", "ident"), column("frozen", "name", writable: false),
            ],
            baseColumns: [
                base("id", nullable: false), base("gen", writable: false),
                base("ident", nullable: false, assigns: true, writable: false), base("name"),
            ]
        )
        let target = try #require(answer.writeTarget)
        #expect(target.readOnlyColumns == ["q2", "gen", "ident", "frozen"])
        #expect(target.baseColumns["ident"]?.assignsValue == true)
        #expect(target.baseColumns["q2"] == nil)
    }

    @Test("A base column shown twice is written through its first showing only")
    func duplicateShowingIsReadOnly() throws {
        let answer = resolve(columns: [column("id", "id"), column("id_again", "id")], baseColumns: [base("id")])
        let target = try #require(answer.writeTarget)
        #expect(target.keyColumns == ["id"])
        #expect(target.readOnlyColumns == ["id_again"])
    }

    @Test("Insert needs every required base column shown as a writable view column")
    func insertNeedsRequiredColumns() throws {
        let required = base("code", nullable: false)
        let shown = resolve(
            columns: [column("id", "id"), column("code", "code")],
            baseColumns: [base("id", nullable: false, defaultValue: "nextval('t_id_seq')"), required]
        )
        #expect(try #require(shown.writeTarget).operations == .all)

        let hidden = resolve(
            columns: [column("id", "id")],
            baseColumns: [base("id", nullable: false, assigns: true), required]
        )
        #expect(try #require(hidden.writeTarget).operations == [.update, .delete])

        let refused = resolve(
            columns: [column("id", "id"), column("code", "code", writable: false)],
            baseColumns: [base("id", nullable: false, assigns: true), required]
        )
        #expect(try #require(refused.writeTarget).operations == [.update, .delete])
    }

    @Test("Base columns the user cannot read keep the edit and the delete but drop the insert")
    func unreadableBaseColumnsDropInsert() throws {
        let answer = resolve(columns: [column("id", "id"), column("q2", nil, writable: false)], baseColumns: nil)
        let target = try #require(answer.writeTarget)
        #expect(target.operations == [.update, .delete])
        #expect(target.readOnlyColumns == ["q2"])
        #expect(target.baseColumns.isEmpty)
    }

    @Test("A NOT NULL column with a default, an identity or a generated value is not required on insert")
    func requiredOnInsert() {
        #expect(base("a", nullable: false).isRequiredOnInsert)
        #expect(!base("b", nullable: false, defaultValue: "0").isRequiredOnInsert)
        #expect(!base("c", nullable: false, assigns: true).isRequiredOnInsert)
        #expect(!base("d", nullable: false, writable: false).isRequiredOnInsert)
        #expect(!base("e").isRequiredOnInsert)
    }

    @Test("The server's operations narrow what the grid offers")
    func serverOperationsCarryThrough() throws {
        let answer = resolve(operations: [.update], columns: [column("id", "id")], baseColumns: [base("id")])
        #expect(try #require(answer.writeTarget).operations == [.update])
    }
}
