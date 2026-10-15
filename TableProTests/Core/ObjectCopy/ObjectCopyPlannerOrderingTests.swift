//
//  ObjectCopyPlannerOrderingTests.swift
//  TableProTests
//
//  What order the plan runs in. A foreign key inside a CREATE TABLE names a
//  table that has to exist already, and a view selects from a table.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct ObjectCopyPlannerOrderingTests {
    private func selection(
        _ name: String,
        kind: CompareObjectKind = .table,
        schema: String? = "public",
        signature: String? = nil,
        owner: String? = nil
    ) -> ObjectCopySelection {
        ObjectCopySelection(kind: kind, name: name, schema: schema, signature: signature, owner: owner)
    }

    /// `schema: nil` on the table is what MySQL and PostgreSQL actually report, and it is the case
    /// the ordering used to get wrong.
    private func read(
        _ name: String,
        tableSchema: String? = nil,
        referencing parents: [String] = [],
        referencedSchema: String? = "public"
    ) -> TableStructureRead {
        TableStructureRead(
            table: PluginTableInfo(name: name, type: "TABLE", schema: tableSchema, comment: nil),
            columns: [PluginColumnInfo(name: "id", dataType: "int")],
            indexes: [],
            foreignKeys: parents.map { parent in
                PluginForeignKeyInfo(
                    name: "fk_\(name)_\(parent)",
                    column: "\(parent)_id",
                    referencedTable: parent,
                    referencedColumn: "id",
                    referencedSchema: referencedSchema
                )
            },
            metadata: nil,
            failure: nil
        )
    }

    @Test
    func aParentIsCreatedBeforeItsChild() {
        let orders = selection("orders")
        let customers = selection("customers")
        let reads: [ObjectCopySelection: TableStructureRead] = [
            orders: read("orders", referencing: ["customers"]),
            customers: read("customers")
        ]

        let ordered = ObjectCopyPlanner.orderedByDependency(
            [orders, customers], reads: reads, effectiveSchema: "public"
        )

        #expect(ordered.map(\.name) == ["customers", "orders"])
    }

    /// The regression this guards: `fetchTables` reports no schema while the foreign key reports
    /// one, so a node keyed `orders` never matched the dependency `public.customers`. Every edge
    /// vanished and the sort fell through to alphabetical order, which puts the child first.
    @Test
    func theEffectiveSchemaIsUsedWhenTheTableReportsNone() {
        let orders = selection("orders", schema: nil)
        let customers = selection("customers", schema: nil)
        let reads: [ObjectCopySelection: TableStructureRead] = [
            orders: read("orders", referencing: ["customers"], referencedSchema: "public"),
            customers: read("customers")
        ]

        let ordered = ObjectCopyPlanner.orderedByDependency(
            [orders, customers], reads: reads, effectiveSchema: "public"
        )

        #expect(ordered.map(\.name) == ["customers", "orders"],
            "the edge has to survive the schema the table itself does not report")
    }

    /// A cycle cannot be ordered, and dropping one of its tables would be worse than letting the
    /// server refuse the second CREATE, so every input still comes back exactly once.
    @Test
    func aCycleStillReturnsEveryTableOnce() {
        let first = selection("a")
        let second = selection("b")
        let reads: [ObjectCopySelection: TableStructureRead] = [
            first: read("a", referencing: ["b"]),
            second: read("b", referencing: ["a"])
        ]

        let ordered = ObjectCopyPlanner.orderedByDependency(
            [first, second], reads: reads, effectiveSchema: "public"
        )

        #expect(Set(ordered.map(\.name)) == ["a", "b"])
        #expect(ordered.count == 2)
    }

    @Test
    func aSingleTableIsReturnedUnchanged() {
        let only = selection("orders")
        #expect(ObjectCopyPlanner.orderedByDependency(
                [only], reads: [only: read("orders")], effectiveSchema: "public"
            ).map(\.name) == ["orders"])
    }

    @Test
    func viewsRunBeforeRoutinesAndTriggersRunLast() {
        let ordered = ObjectCopyPlanner.orderedByKind([
            selection("audit_trigger", kind: .trigger),
            selection("total_sales", kind: .procedure),
            selection("active_users", kind: .view),
            selection("tax_rate", kind: .function)
        ])

        #expect(ordered.map(\.name) == ["active_users", "tax_rate", "total_sales", "audit_trigger"])
    }

    @Test
    func twoObjectsOfOneKindKeepTheirGivenOrder() {
        let ordered = ObjectCopyPlanner.orderedByKind([
            selection("second", kind: .view),
            selection("first", kind: .view)
        ])

        #expect(ordered.map(\.name) == ["second", "first"])
    }

    // MARK: - Matching what the target already has

    /// Engines fold identifier case differently, and a target that already has the object has to
    /// be recognised whichever way it spells it, or Skip does not skip and Replace does not drop.
    @Test
    func anExistingObjectMatchesWithoutRegardToCase() {
        #expect(ObjectCopyPlanner.objectKey(for: selection("Active_Users", kind: .view)) == ObjectCopyPlanner.objectKey(for: selection("active_users", kind: .view)))
    }

    /// A table and a trigger may share a name, and only the trigger's own presence decides the
    /// trigger's step.
    @Test
    func twoKindsSharingANameAreDifferentObjects() {
        #expect(ObjectCopyPlanner.objectKey(for: selection("audit", kind: .table)) != ObjectCopyPlanner.objectKey(for: selection("audit", kind: .trigger, owner: "orders")))
    }

    /// A materialized view occupies a view's name, and a function occupies a procedure's on
    /// several engines, so each pair is one object for the purpose of "is it already there".
    @Test
    func viewsAndRoutinesFoldIntoOneFamilyEach() {
        #expect(ObjectCopyPlanner.objectKey(for: selection("sales", kind: .view)) == ObjectCopyPlanner.objectKey(for: selection("sales", kind: .materializedView)))
        #expect(ObjectCopyPlanner.objectKey(for: selection("total", kind: .procedure)) == ObjectCopyPlanner.objectKey(for: selection("total", kind: .function)))
    }

    /// `f(integer)` and `f(text)` are two routines, and copying one must not be taken for the
    /// other already being there.
    @Test
    func twoOverloadsAreTwoObjects() {
        #expect(ObjectCopyPlanner.objectKey(for: selection("f", kind: .function, signature: "(integer)")) != ObjectCopyPlanner.objectKey(for: selection("f", kind: .function, signature: "(text)")))
    }

    @Test
    func twoTriggersOnDifferentTablesAreTwoObjects() {
        #expect(ObjectCopyPlanner.objectKey(for: selection("audit", kind: .trigger, owner: "orders")) != ObjectCopyPlanner.objectKey(for: selection("audit", kind: .trigger, owner: "customers")))
    }

    // MARK: - Namespace scopes

    private func request(
        _ objects: [ObjectCopySelection],
        duplicates: Bool = false
    ) -> ObjectCopyRequest {
        let source = DatabaseEndpoint(
            scope: DatabaseScope(connectionId: UUID(), database: "shop", schema: nil),
            connectionName: "server",
            databaseType: .postgresql,
            safeModeLevel: .silent,
            color: .blue
        )
        return ObjectCopyRequest(
            source: source,
            destination: duplicates
                ? .newDatabase(base: source, name: "shop_copy", values: [:])
                : .existing(source.withDatabase("other").withSchema("archive")),
            objects: objects,
            content: .structureAndData,
            existingPolicy: .skip
        )
    }

    /// A database-level copy on PostgreSQL spans every schema, and each has to be read and written
    /// in its own scope: one read against a nil schema answers only whatever the connection is on.
    @Test
    func objectsAreGroupedByTheSchemaTheyWereFoundIn() {
        let scopes = ObjectCopyPlanner.scopes(of: request([
            selection("orders", schema: "sales"),
            selection("audit", schema: "logging"),
            selection("customers", schema: "sales")
        ]))

        #expect(scopes.map(\.namespace) == ["sales", "logging"])
        #expect(scopes.first?.objects.map(\.name) == ["orders", "customers"])
    }

    /// A duplicate keeps every schema name, so each schema's objects land in a schema of the same
    /// name in the new database. A copy to a chosen target puts them all in the schema chosen.
    @Test
    func aDuplicateKeepsEachSchemaNameAndACopyDoesNot() {
        let objects = [selection("orders", schema: "sales")]
        let duplicate = ObjectCopyPlanner.scopes(of: request(objects, duplicates: true))
        let copy = ObjectCopyPlanner.scopes(of: request(objects))

        #expect(duplicate.first?.targetNamespace(for: request(objects, duplicates: true)) == "sales")
        #expect(copy.first?.targetNamespace(for: request(objects)) == "archive")
    }

    @Test
    func anEngineWithoutSchemasIsOneScope() {
        let scopes = ObjectCopyPlanner.scopes(of: request([
            selection("orders", schema: nil),
            selection("customers", schema: nil)
        ]))

        #expect(scopes.count == 1)
        #expect(scopes.first?.namespace == nil)
    }

    // MARK: - Retargeting foreign keys

    private func snapshot(referencedSchema: String?) -> TableStructureSnapshot {
        TableStructureSnapshot(
            name: "orders",
            schema: "sales",
            columns: [],
            foreignKeys: [EditableForeignKeyDefinition(
                id: UUID(),
                name: "fk",
                columns: ["customer_id"],
                referencedTable: "customers",
                referencedColumns: ["id"],
                referencedSchema: referencedSchema,
                onDelete: .noAction,
                onUpdate: .noAction
            )]
        )
    }

    /// Left as it was, the copied child kept referencing the source's parent, so `prod_copy.orders`
    /// stayed wired to `prod.customers` and the duplicate was never independent of its original.
    @Test
    func aForeignKeyIntoTheSourceIsMovedToTheTarget() {
        let moved = ObjectCopyPlanner.retargeted(
            snapshot(referencedSchema: "sales"), from: "sales", to: "archive", schema: "archive"
        )

        #expect(moved.schema == "archive")
        #expect(moved.foreignKeys.first?.referencedSchema == "archive")
    }

    /// A reference that names neither side's schema points at something the copy never touched.
    @Test
    func aForeignKeyIntoAThirdSchemaIsLeftAlone() {
        let moved = ObjectCopyPlanner.retargeted(
            snapshot(referencedSchema: "reference"), from: "sales", to: "archive", schema: "archive"
        )

        #expect(moved.foreignKeys.first?.referencedSchema == "reference")
    }

    /// An unqualified reference means "my own schema", so it follows the table into the target.
    @Test
    func anUnqualifiedForeignKeyFollowsTheTable() {
        let moved = ObjectCopyPlanner.retargeted(
            snapshot(referencedSchema: nil), from: "sales", to: "archive", schema: "archive"
        )

        #expect(moved.foreignKeys.first?.referencedSchema == "archive")
    }

    @Test
    func aSchemaThatDoesNotChangeLeavesTheSnapshotAlone() {
        let moved = ObjectCopyPlanner.retargeted(
            snapshot(referencedSchema: "sales"), from: "sales", to: "sales", schema: "sales"
        )

        #expect(moved.foreignKeys.first?.referencedSchema == "sales")
    }

    /// A table the sort could not place is appended in the caller's own order, which is why the
    /// caller has to hand one in. Seeded from `reads.keys` the tail came out in whatever order
    /// Swift's per-process hash seed gave the dictionary that launch, so the same copy produced a
    /// different approved script, progress order and outcome list from one run to the next.
    @Test
    func tablesTheSortCannotPlaceFollowTheOrderTheyWereGivenIn() {
        let placed = selection("customers")
        let names = ["zulu", "alpha", "mike"]
        let unread = names.map { selection($0) }
        let reads: [ObjectCopySelection: TableStructureRead] = [placed: read("customers")]

        let ordered = ObjectCopyPlanner.orderedByDependency(
            [placed] + unread, reads: reads, effectiveSchema: "public"
        )

        #expect(ordered.map(\.name) == ["customers"] + names)
    }

    /// The same selections in the same order answer the same way every time, whatever order the
    /// reads were built in.
    @Test
    func theOrderDoesNotDependOnHowTheReadsWereBuilt() {
        let names = ["zulu", "alpha", "mike", "bravo", "yankee"]
        let selections = names.map { selection($0) }
        var forwards: [ObjectCopySelection: TableStructureRead] = [:]
        for (selection, name) in zip(selections, names) { forwards[selection] = read(name) }
        var backwards: [ObjectCopySelection: TableStructureRead] = [:]
        for (selection, name) in zip(selections, names).reversed() { backwards[selection] = read(name) }

        let first = ObjectCopyPlanner.orderedByDependency(
            selections, reads: forwards, effectiveSchema: "public"
        )
        let second = ObjectCopyPlanner.orderedByDependency(
            selections, reads: backwards, effectiveSchema: "public"
        )

        #expect(first.map(\.name) == second.map(\.name))
        #expect(Set(first.map(\.name)) == Set(names))
        #expect(first.count == names.count)
    }

    /// The tie-break holds while a real dependency still moves the tables it names.
    @Test
    func theGivenOrderYieldsToAForeignKey() {
        let orders = selection("orders")
        let customers = selection("customers")
        let audit = selection("audit")
        let reads: [ObjectCopySelection: TableStructureRead] = [
            orders: read("orders", referencing: ["customers"]),
            customers: read("customers"),
            audit: read("audit")
        ]

        let ordered = ObjectCopyPlanner.orderedByDependency(
            [orders, audit, customers], reads: reads, effectiveSchema: "public"
        )

        guard let parent = ordered.firstIndex(of: customers),
              let child = ordered.firstIndex(of: orders) else {
            Issue.record("the sort dropped a table")
            return
        }
        #expect(parent < child)
        #expect(ordered.count == 3)
    }
}
