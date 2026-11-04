import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct CascadeDeletePlanTests {
    private static func key(
        _ name: String,
        _ table: String,
        _ columns: [String],
        references parent: String,
        _ parentColumns: [String],
        _ action: ReferencingKey.Action
    ) -> ReferencingKey {
        ReferencingKey(
            name: name,
            table: table,
            columns: columns,
            referencedTable: parent,
            referencedColumns: parentColumns,
            action: action
        )
    }

    private static func customers(_ ids: [String]) -> CascadeDeleteRoot {
        CascadeDeleteRoot(
            table: "customers",
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            rows: ids.map { [.text($0), .text("name \($0)")] }
        )
    }

    private static let customerRows = CascadeRowSet.keyed(table: "customers", columns: ["id"], values: [["1"], ["2"]])

    @Test("A cascade two levels deep becomes two delete effects, each reached through its parent")
    func twoLevelCascade() {
        let plan = CascadeDeletePlan.walk(
            root: Self.customers(["1", "2"]),
            keys: [
                Self.key("fk_orders", "orders", ["customer_id"], references: "customers", ["id"], .cascade),
                Self.key("fk_items", "order_items", ["order_id"], references: "orders", ["id"], .cascade)
            ]
        )

        let orders = CascadeRowSet.referencing(
            table: "orders", columns: ["customer_id"], parentColumns: ["id"], parent: Self.customerRows
        )
        let items = CascadeRowSet.referencing(
            table: "order_items", columns: ["order_id"], parentColumns: ["id"], parent: orders
        )
        #expect(plan.effects.map(\.table) == ["orders", "order_items"])
        #expect(plan.effects.map(\.kind) == [.delete, .delete])
        #expect(plan.effects[0].paths == [orders])
        #expect(plan.effects[1].paths == [items])
        #expect(plan.stoppedAtDepth == false)
        #expect(plan.leftKeysUnfollowed == false)
    }

    @Test("SET NULL, SET DEFAULT and refusing keys are effects that stop the walk")
    func nonCascadingActionsDoNotRecurse() {
        let plan = CascadeDeletePlan.walk(
            root: Self.customers(["1"]),
            keys: [
                Self.key("fk_invoices", "invoices", ["customer_id"], references: "customers", ["id"], .setNull),
                Self.key("fk_notes", "notes", ["customer_id"], references: "customers", ["id"], .setDefault),
                Self.key("fk_payments", "payments", ["customer_id"], references: "customers", ["id"], .restrict),
                Self.key("fk_lines", "invoice_lines", ["invoice_id"], references: "invoices", ["id"], .cascade)
            ]
        )

        #expect(plan.effects.map(\.table) == ["invoices", "notes", "payments"])
        #expect(plan.effects.map(\.kind) == [
            .setNull(columns: ["customer_id"]),
            .setDefault(columns: ["customer_id"]),
            .block
        ])
        #expect(plan.effects[2].constraints == ["fk_payments"])
    }

    @Test("A refusing key behind a cascade still blocks the delete")
    func refusingKeyBehindACascade() {
        let plan = CascadeDeletePlan.walk(
            root: Self.customers(["1"]),
            keys: [
                Self.key("fk_orders", "orders", ["customer_id"], references: "customers", ["id"], .cascade),
                Self.key("fk_shipments", "shipments", ["order_id"], references: "orders", ["id"], .noAction)
            ]
        )

        #expect(plan.effects.last?.table == "shipments")
        #expect(plan.effects.last?.kind == .block)
    }

    @Test("A chain longer than the depth limit stops there and says so")
    func depthLimitTruncates() {
        let tables = (1...7).map { "t\($0)" }
        var keys: [ReferencingKey] = []
        var parent = "customers"
        for table in tables {
            keys.append(Self.key("fk_\(table)", table, ["parent_id"], references: parent, ["id"], .cascade))
            parent = table
        }

        let plan = CascadeDeletePlan.walk(root: Self.customers(["1"]), keys: keys)

        #expect(plan.effects.map(\.table) == Array(tables.prefix(CascadeDeletePlan.maximumDepth)))
        #expect(plan.stoppedAtDepth)
    }

    @Test("A chain that ends at the depth limit is complete")
    func chainEndingAtTheLimitIsNotTruncated() {
        let tables = (1...CascadeDeletePlan.maximumDepth).map { "t\($0)" }
        var keys: [ReferencingKey] = []
        var parent = "customers"
        for table in tables {
            keys.append(Self.key("fk_\(table)", table, ["parent_id"], references: parent, ["id"], .cascade))
            parent = table
        }

        let plan = CascadeDeletePlan.walk(root: Self.customers(["1"]), keys: keys)

        #expect(plan.effects.count == CascadeDeletePlan.maximumDepth)
        #expect(plan.stoppedAtDepth == false)
    }

    @Test("A self-referencing cascade is one effect on the table itself, cut off at the depth limit")
    func selfReferencingCascade() {
        let root = CascadeDeleteRoot(
            table: "employees", columns: ["id", "manager_id"], primaryKeyColumns: ["id"], rows: [[.text("1"), .null]]
        )
        let plan = CascadeDeletePlan.walk(
            root: root,
            keys: [Self.key("fk_manager", "employees", ["manager_id"], references: "employees", ["id"], .cascade)]
        )

        #expect(plan.effects.count == 1)
        #expect(plan.effects[0].table == "employees")
        #expect(plan.effects[0].paths.count == CascadeDeletePlan.maximumDepth)
        #expect(plan.stoppedAtDepth)
    }

    @Test("Two routes to one table are one effect counted as a union")
    func diamondIsOneEffect() {
        let plan = CascadeDeletePlan.walk(
            root: Self.customers(["1"]),
            keys: [
                Self.key("fk_orders", "orders", ["customer_id"], references: "customers", ["id"], .cascade),
                Self.key("fk_tickets", "tickets", ["customer_id"], references: "customers", ["id"], .cascade),
                Self.key("fk_notes_order", "notes", ["order_id"], references: "orders", ["id"], .cascade),
                Self.key("fk_notes_ticket", "notes", ["ticket_id"], references: "tickets", ["id"], .cascade)
            ]
        )

        let notes = plan.effects.filter { $0.table == "notes" }
        #expect(notes.count == 1)
        #expect(notes.first?.paths.count == 2)
        #expect(notes.first?.constraints == ["fk_notes_order", "fk_notes_ticket"])
    }

    @Test("The hop limit ends the walk and marks it incomplete")
    func hopLimitTruncates() {
        let keys = (1...5).map {
            Self.key("fk_\($0)", "child\($0)", ["customer_id"], references: "customers", ["id"], .setNull)
        }

        let plan = CascadeDeletePlan.walk(root: Self.customers(["1"]), keys: keys, maximumHops: 3)

        #expect(plan.effects.count == 3)
        #expect(plan.leftKeysUnfollowed)
        #expect(plan.stoppedAtDepth == false)
    }

    @Test("A table without a primary key names its deleted rows by the referenced columns")
    func rootWithoutPrimaryKey() {
        let root = CascadeDeleteRoot(
            table: "accounts", columns: ["code", "label"], primaryKeyColumns: [], rows: [[.text("A1"), .text("x")]]
        )
        let plan = CascadeDeletePlan.walk(
            root: root,
            keys: [Self.key("fk_ledger", "ledger", ["account_code"], references: "accounts", ["code"], .cascade)]
        )

        #expect(plan.effects.first?.paths == [
            .referencing(
                table: "ledger",
                columns: ["account_code"],
                parentColumns: ["code"],
                parent: .keyed(table: "accounts", columns: ["code"], values: [["A1"]])
            )
        ])
    }

    @Test("Deleted rows holding NULL in the referenced column cannot be referenced")
    func nullReferencedValuesAreSkipped() {
        let root = CascadeDeleteRoot(
            table: "accounts", columns: ["code"], primaryKeyColumns: [], rows: [[.null], [.null]]
        )
        let plan = CascadeDeletePlan.walk(
            root: root,
            keys: [Self.key("fk_ledger", "ledger", ["account_code"], references: "accounts", ["code"], .noAction)]
        )

        #expect(plan.effects.isEmpty)
    }

    @Test("Rows the grid could not describe leave the effect listed but uncountable")
    func incompleteRootIsUncountable() {
        let root = CascadeDeleteRoot(
            table: "customers", columns: ["id"], primaryKeyColumns: ["id"], rows: [[.text("1")]], isComplete: false
        )
        let plan = CascadeDeletePlan.walk(
            root: root,
            keys: [
                Self.key("fk_orders", "orders", ["customer_id"], references: "customers", ["id"], .cascade),
                Self.key("fk_items", "order_items", ["order_id"], references: "orders", ["id"], .cascade)
            ]
        )

        #expect(plan.effects.map(\.table) == ["orders", "order_items"])
        #expect(plan.effects.allSatisfy { !$0.isCountable })
    }

    @Test("A binary key value cannot be written as text, so the effect is uncountable")
    func binaryKeyIsUncountable() {
        let root = CascadeDeleteRoot(
            table: "blobs", columns: ["id"], primaryKeyColumns: ["id"], rows: [[.bytes(Data([1, 2]))]]
        )
        let plan = CascadeDeletePlan.walk(
            root: root,
            keys: [Self.key("fk_parts", "parts", ["blob_id"], references: "blobs", ["id"], .cascade)]
        )

        #expect(plan.effects.first?.isCountable == false)
    }

    @Test("A table a cascade also deletes from keeps those rows out of its block and rewrite counts")
    func rowsDeletedAnyway() {
        let root = Self.customers(["1"])
        let plan = CascadeDeletePlan.walk(
            root: root,
            keys: [
                Self.key("fk_orders", "orders", ["customer_id"], references: "customers", ["id"], .cascade),
                Self.key("fk_notes_order", "notes", ["order_id"], references: "orders", ["id"], .cascade),
                Self.key("fk_notes_customer", "notes", ["customer_id"], references: "customers", ["id"], .noAction),
                Self.key("fk_tags_customer", "notes", ["tagged_id"], references: "customers", ["id"], .restrict),
                Self.key("fk_manager", "customers", ["referrer_id"], references: "customers", ["id"], .setNull)
            ]
        )

        let deletedNotes = plan.effects.first { $0.table == "notes" && $0.kind == .delete }
        let blockingNotes = plan.effects.first { $0.table == "notes" && $0.kind == .block }
        let referrers = plan.effects.first { $0.table == "customers" }
        #expect(blockingNotes.map { plan.rowsDeletedAnyway(alongside: $0, root: root) } == deletedNotes?.paths)
        #expect(deletedNotes.map { plan.rowsDeletedAnyway(alongside: $0, root: root) } == [])
        #expect(referrers.map { plan.rowsDeletedAnyway(alongside: $0, root: root) } == [root.primaryKeyRows].compactMap { $0 })
    }

    @Test("A rewritten column that is itself a parent key leaves its ON UPDATE rule unfollowed, and says so")
    func rewrittenParentKey() {
        let plan = CascadeDeletePlan.walk(
            root: Self.customers(["1"]),
            keys: [
                Self.key("fk_accounts", "accounts", ["customer_id"], references: "customers", ["id"], .setNull),
                Self.key("fk_ledger", "ledger", ["account_customer"], references: "accounts", ["customer_id"], .noAction)
            ]
        )
        let unrelated = CascadeDeletePlan.walk(
            root: Self.customers(["1"]),
            keys: [
                Self.key("fk_accounts", "accounts", ["customer_id"], references: "customers", ["id"], .setNull),
                Self.key("fk_ledger", "ledger", ["account_id"], references: "accounts", ["id"], .noAction)
            ]
        )

        #expect(plan.effects.map(\.table) == ["accounts"])
        #expect(plan.leftKeysUnfollowed)
        #expect(unrelated.leftKeysUnfollowed == false)
    }

    @Test("The deleted rows are read from the plan's delete operations")
    func rootFromOperations() {
        let target = DataWriteTarget(database: "shop", schema: "public", table: "customers")
        let delete = RowWriteOperation(
            kind: .delete, target: target, columns: ["id"], primaryKeyColumns: ["id"],
            preImage: [.text("7")], postImage: nil, writtenColumns: ["id"], refusal: nil
        )
        let update = RowWriteOperation(
            kind: .update, target: target, columns: ["id"], primaryKeyColumns: ["id"],
            preImage: [.text("8")], postImage: [.text("9")], writtenColumns: ["id"], refusal: nil
        )

        let root = CascadeDeleteRoot(operations: [update, delete])

        #expect(root?.table == "customers")
        #expect(root?.rows == [[.text("7")]])
        #expect(root?.primaryKeyRows == .keyed(table: "customers", columns: ["id"], values: [["7"]]))
        #expect(root?.editedColumns == ["id"])
        #expect(CascadeDeleteRoot(operations: [update]) == nil)
    }

    @Test("An edit in the same save to a key column of the table is noticed")
    func editedKeyColumns() {
        let keys = [
            Self.key("fk_manager", "customers", ["referrer_id"], references: "customers", ["id"], .cascade),
            Self.key("fk_orders", "orders", ["customer_id"], references: "customers", ["code"], .cascade)
        ]
        func root(editing columns: Set<String>) -> CascadeDeleteRoot {
            CascadeDeleteRoot(
                table: "customers", columns: ["id"], primaryKeyColumns: ["id"], rows: [[.text("1")]], editedColumns: columns
            )
        }
        let names = CascadeTableNames(ignoresCase: false)

        #expect(root(editing: ["referrer_id"]).editsKeyColumns(of: keys, tableNames: names))
        #expect(root(editing: ["code"]).editsKeyColumns(of: keys, tableNames: names))
        #expect(root(editing: ["name"]).editsKeyColumns(of: keys, tableNames: names) == false)
        #expect(root(editing: []).editsKeyColumns(of: keys, tableNames: names) == false)
    }

    @Test("Rows deleted through a view cascade from its table, under the table's column names")
    func viewDeleteStartsAtTheBaseTable() {
        let viewRoot = CascadeDeleteRoot(
            table: "v_customers",
            columns: ["customer_id", "label", "total"],
            primaryKeyColumns: ["customer_id"],
            rows: [[.text("1"), .text("a"), .text("3")]],
            editedColumns: ["label"]
        )
        let target = TestFixtures.viewTarget(
            base: PluginViewBaseTable(schema: "public", name: "customers"),
            keys: ["customer_id"],
            readOnly: ["total"],
            baseColumnNames: ["customer_id": "id", "label": "name"]
        )

        let root = viewRoot.onBaseTable(of: target)

        #expect(root.table == "customers")
        #expect(root.columns == ["id", "name"])
        #expect(root.rows == [[.text("1"), .text("a")]])
        #expect(root.primaryKeyColumns == ["id"])
        #expect(root.editedColumns == ["name"])
        #expect(root.primaryKeyRows == .keyed(table: "customers", columns: ["id"], values: [["1"]]))
    }

    @Test("A view's table in another database cannot be previewed, one in another schema can")
    func viewCascadeScope() {
        let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "reporting")
        func plan(_ base: PluginViewBaseTable?) -> DataWritePlan {
            var plan = DataWritePlan(scope: scope, databaseType: .postgresql, steps: [])
            plan.viewTarget = base.map { TestFixtures.viewTarget(base: $0, keys: ["id"]) }
            return plan
        }

        #expect(plan(nil).cascadeScope == scope)
        #expect(plan(PluginViewBaseTable(schema: "public", name: "t")).cascadeScope?.schema == "public")
        #expect(plan(PluginViewBaseTable(database: "shop", name: "t")).cascadeScope == scope)
        #expect(plan(PluginViewBaseTable(database: "archive", name: "t")).cascadeScope == nil)
    }
}

struct ReferencingKeyTests {
    private let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: "public")

    @Test("Catalog spellings of the delete action map to what the database does",
          arguments: [
              ("CASCADE", ReferencingKey.Action.cascade),
              ("cascade", .cascade),
              ("SET NULL", .setNull),
              ("SET_NULL", .setNull),
              ("SET DEFAULT", .setDefault),
              ("SET_DEFAULT", .setDefault),
              ("RESTRICT", .restrict),
              ("restrict", .restrict),
              ("NO ACTION", .noAction),
              ("NO_ACTION", .noAction),
              ("", .noAction)
          ])
    func actionSpellings(value: String, action: ReferencingKey.Action) {
        #expect(ReferencingKey.action(forCatalogValue: value) == action)
    }

    @Test("Per-column catalog rows regroup into one composite key")
    func compositeKeyRegroups() {
        let keys = ReferencingKey.keys(
            from: [
                "order_lines": [
                    ForeignKeyInfo(
                        name: "fk_line_order", column: "order_no", referencedTable: "orders",
                        referencedColumn: "no", referencedSchema: "public", onDelete: "CASCADE"
                    ),
                    ForeignKeyInfo(
                        name: "fk_line_order", column: "order_year", referencedTable: "orders",
                        referencedColumn: "year", referencedSchema: "public", onDelete: "CASCADE"
                    ),
                    ForeignKeyInfo(
                        name: "fk_line_product", column: "product_id", referencedTable: "products",
                        referencedColumn: "id", referencedSchema: "public", onDelete: "RESTRICT"
                    )
                ]
            ],
            pointingInto: scope,
            slot: .schema
        )

        #expect(keys == [
            ReferencingKey(
                name: "fk_line_order", table: "order_lines", columns: ["order_no", "order_year"],
                referencedTable: "orders", referencedColumns: ["no", "year"], action: .cascade
            ),
            ReferencingKey(
                name: "fk_line_product", table: "order_lines", columns: ["product_id"],
                referencedTable: "products", referencedColumns: ["id"], action: .restrict
            )
        ])
    }

    @Test("Unnamed keys are never merged")
    func unnamedKeysStandAlone() {
        let keys = ReferencingKey.keys(
            from: [
                "notes": [
                    ForeignKeyInfo(name: "", column: "a_id", referencedTable: "a", referencedColumn: "id"),
                    ForeignKeyInfo(name: "", column: "b_id", referencedTable: "b", referencedColumn: "id")
                ]
            ],
            pointingInto: DatabaseScope(connectionId: UUID(), database: "main", schema: nil),
            slot: .unqualified
        )

        #expect(keys.map(\.columns) == [["a_id"], ["b_id"]])
    }

    @Test("A key into another schema names a different table and is left out")
    func otherSchemaIsIgnored() {
        let keys = ReferencingKey.keys(
            from: [
                "orders": [
                    ForeignKeyInfo(
                        name: "fk_audit", column: "customer_id", referencedTable: "customers",
                        referencedColumn: "id", referencedSchema: "audit", onDelete: "CASCADE"
                    ),
                    ForeignKeyInfo(
                        name: "fk_customer", column: "customer_id", referencedTable: "customers",
                        referencedColumn: "id", referencedSchema: "public", onDelete: "CASCADE"
                    )
                ]
            ],
            pointingInto: scope,
            slot: .schema
        )

        #expect(keys.map(\.name) == ["fk_customer"])
    }

    @Test("An engine without schemas names the referenced database in the schema column")
    func databaseSlot() {
        let mysqlScope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)
        let keys = ReferencingKey.keys(
            from: [
                "orders": [
                    ForeignKeyInfo(
                        name: "fk_customer", column: "customer_id", referencedTable: "customers",
                        referencedColumn: "id", referencedSchema: "shop", onDelete: "CASCADE"
                    ),
                    ForeignKeyInfo(
                        name: "fk_other", column: "legacy_id", referencedTable: "customers",
                        referencedColumn: "id", referencedSchema: "legacy", onDelete: "CASCADE"
                    )
                ]
            ],
            pointingInto: mysqlScope,
            slot: .database
        )

        #expect(keys.map(\.name) == ["fk_customer"])
    }
}
