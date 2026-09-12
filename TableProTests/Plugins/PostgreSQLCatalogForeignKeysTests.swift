import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQLCatalogForeignKeys")
struct PostgreSQLCatalogForeignKeysTests {
    private func row(
        identity: String = "100",
        name: String,
        referencedSchema: String? = "app",
        referencedTable: String = "parent",
        deleteAction: String = "a",
        updateAction: String = "a",
        sourceKeys: String,
        referencedKeys: String,
        side: String,
        attributeNumber: Int,
        attributeName: String
    ) -> [String?] {
        var cells: [String?] = Array(repeating: nil, count: PostgreSQLCatalogForeignKeys.Column.allCases.count)
        cells[PostgreSQLCatalogForeignKeys.Column.constraintIdentity.rawValue] = identity
        cells[PostgreSQLCatalogForeignKeys.Column.constraintName.rawValue] = name
        cells[PostgreSQLCatalogForeignKeys.Column.referencedSchema.rawValue] = referencedSchema
        cells[PostgreSQLCatalogForeignKeys.Column.referencedTable.rawValue] = referencedTable
        cells[PostgreSQLCatalogForeignKeys.Column.deleteAction.rawValue] = deleteAction
        cells[PostgreSQLCatalogForeignKeys.Column.updateAction.rawValue] = updateAction
        cells[PostgreSQLCatalogForeignKeys.Column.sourceKeys.rawValue] = sourceKeys
        cells[PostgreSQLCatalogForeignKeys.Column.referencedKeys.rawValue] = referencedKeys
        cells[PostgreSQLCatalogForeignKeys.Column.side.rawValue] = side
        cells[PostgreSQLCatalogForeignKeys.Column.attributeNumber.rawValue] = String(attributeNumber)
        cells[PostgreSQLCatalogForeignKeys.Column.attributeName.rawValue] = attributeName
        return cells
    }

    private func pairs(_ keys: [PluginForeignKeyInfo]) -> [String] {
        keys.map { "\($0.name):\($0.column)->\($0.referencedTable).\($0.referencedColumn)" }
    }

    @Test("A composite key yields one pair per column, in key order")
    func compositeKeyPairsByPosition() {
        let rows = [
            row(name: "fk_xy", sourceKeys: "{2,3}", referencedKeys: "{1,2}", side: "r", attributeNumber: 1, attributeName: "x"),
            row(name: "fk_xy", sourceKeys: "{2,3}", referencedKeys: "{1,2}", side: "r", attributeNumber: 2, attributeName: "y"),
            row(name: "fk_xy", sourceKeys: "{2,3}", referencedKeys: "{1,2}", side: "s", attributeNumber: 2, attributeName: "a"),
            row(name: "fk_xy", sourceKeys: "{2,3}", referencedKeys: "{1,2}", side: "s", attributeNumber: 3, attributeName: "b")
        ]
        let keys = PostgreSQLCatalogForeignKeys.foreignKeys(from: rows)
        #expect(pairs(keys) == ["fk_xy:a->parent.x", "fk_xy:b->parent.y"])
    }

    @Test("Columns listed in a different order than the referenced key pair by the key arrays, not by attribute order")
    func reorderedReferencePairsByKeyArrays() {
        let rows = [
            row(name: "fk_ba", sourceKeys: "{3,2}", referencedKeys: "{2,1}", side: "s", attributeNumber: 2, attributeName: "a"),
            row(name: "fk_ba", sourceKeys: "{3,2}", referencedKeys: "{2,1}", side: "s", attributeNumber: 3, attributeName: "b"),
            row(name: "fk_ba", sourceKeys: "{3,2}", referencedKeys: "{2,1}", side: "r", attributeNumber: 1, attributeName: "x"),
            row(name: "fk_ba", sourceKeys: "{3,2}", referencedKeys: "{2,1}", side: "r", attributeNumber: 2, attributeName: "y")
        ]
        let keys = PostgreSQLCatalogForeignKeys.foreignKeys(from: rows)
        #expect(pairs(keys) == ["fk_ba:b->parent.y", "fk_ba:a->parent.x"])
    }

    @Test("Two constraints with the same name stay separate when their identities differ")
    func sameNameDifferentConstraintsStaySeparate() {
        let rows = [
            row(identity: "1", name: "fk", referencedTable: "one", sourceKeys: "{1}", referencedKeys: "{1}", side: "s", attributeNumber: 1, attributeName: "a"),
            row(identity: "1", name: "fk", referencedTable: "one", sourceKeys: "{1}", referencedKeys: "{1}", side: "r", attributeNumber: 1, attributeName: "id"),
            row(identity: "2", name: "fk", referencedTable: "two", sourceKeys: "{2}", referencedKeys: "{1}", side: "s", attributeNumber: 2, attributeName: "b"),
            row(identity: "2", name: "fk", referencedTable: "two", sourceKeys: "{2}", referencedKeys: "{1}", side: "r", attributeNumber: 1, attributeName: "key")
        ]
        let keys = PostgreSQLCatalogForeignKeys.foreignKeys(from: rows)
        #expect(pairs(keys) == ["fk:a->one.id", "fk:b->two.key"])
    }

    @Test("A self-referencing composite key pairs source and referenced attributes of the same table")
    func selfReferenceUsesBothSides() {
        let rows = [
            row(name: "tree_self", referencedTable: "tree", sourceKeys: "{3,4}", referencedKeys: "{1,2}", side: "s", attributeNumber: 3, attributeName: "pp"),
            row(name: "tree_self", referencedTable: "tree", sourceKeys: "{3,4}", referencedKeys: "{1,2}", side: "s", attributeNumber: 4, attributeName: "pq"),
            row(name: "tree_self", referencedTable: "tree", sourceKeys: "{3,4}", referencedKeys: "{1,2}", side: "r", attributeNumber: 1, attributeName: "p"),
            row(name: "tree_self", referencedTable: "tree", sourceKeys: "{3,4}", referencedKeys: "{1,2}", side: "r", attributeNumber: 2, attributeName: "q")
        ]
        let keys = PostgreSQLCatalogForeignKeys.foreignKeys(from: rows)
        #expect(pairs(keys) == ["tree_self:pp->tree.p", "tree_self:pq->tree.q"])
    }

    @Test("Referenced schema and referential actions come from the catalog row")
    func carriesSchemaAndActions() throws {
        let rows = [("s", "Weird, Col"), ("r", "id")].map { side, attributeName in
            row(
                name: "fk",
                referencedSchema: "billing",
                deleteAction: "c",
                updateAction: "n",
                sourceKeys: "{1}",
                referencedKeys: "{1}",
                side: side,
                attributeNumber: 1,
                attributeName: attributeName
            )
        }
        let key = try #require(PostgreSQLCatalogForeignKeys.foreignKeys(from: rows).first)
        #expect(key.column == "Weird, Col")
        #expect(key.referencedSchema == "billing")
        #expect(key.onDelete == "CASCADE")
        #expect(key.onUpdate == "SET NULL")
    }

    @Test("Every referential action code maps to its SQL keyword")
    func referentialActionCodes() {
        #expect(PostgreSQLCatalogForeignKeys.referentialAction("a") == "NO ACTION")
        #expect(PostgreSQLCatalogForeignKeys.referentialAction("r") == "RESTRICT")
        #expect(PostgreSQLCatalogForeignKeys.referentialAction("c") == "CASCADE")
        #expect(PostgreSQLCatalogForeignKeys.referentialAction("n") == "SET NULL")
        #expect(PostgreSQLCatalogForeignKeys.referentialAction("d") == "SET DEFAULT")
        #expect(PostgreSQLCatalogForeignKeys.referentialAction(nil) == "NO ACTION")
    }

    @Test("Key arrays of different lengths produce no pairs rather than a guessed pairing")
    func mismatchedKeyArraysProduceNothing() {
        let rows = [
            row(name: "fk", sourceKeys: "{1,2}", referencedKeys: "{1}", side: "s", attributeNumber: 1, attributeName: "a"),
            row(name: "fk", sourceKeys: "{1,2}", referencedKeys: "{1}", side: "r", attributeNumber: 1, attributeName: "x")
        ]
        #expect(PostgreSQLCatalogForeignKeys.foreignKeys(from: rows).isEmpty)
    }

    @Test("A row whose key array cannot be read is skipped")
    func unreadableKeyArrayIsSkipped() {
        let rows = [
            row(name: "fk", sourceKeys: "1,2", referencedKeys: "{1,2}", side: "s", attributeNumber: 1, attributeName: "a")
        ]
        #expect(PostgreSQLCatalogForeignKeys.foreignKeys(from: rows).isEmpty)
    }

    @Test("The query filters on the table's own schema and name and reads both key arrays")
    func queryFiltersOnSchemaAndTable() {
        let query = PostgreSQLCatalogForeignKeys.query(
            schemaLiteral: "'sales'",
            tableLiteral: "'orders'",
            excludesPartitionClones: true
        )
        #expect(query.contains("ns.nspname = 'sales'"))
        #expect(query.contains("cl.relname = 'orders'"))
        #expect(query.contains("a.attnum = ANY (c.conkey)"))
        #expect(query.contains("a.attnum = ANY (c.confkey)"))
        #expect(!query.contains("information_schema"))
    }

    @Test("Both branches project every decoded column")
    func branchesProjectEveryColumn() {
        let query = PostgreSQLCatalogForeignKeys.query(
            schemaLiteral: "'public'",
            tableLiteral: "'t'",
            excludesPartitionClones: false
        )
        let branches = query.components(separatedBy: "UNION ALL")
        #expect(branches.count == PostgreSQLCatalogForeignKeys.Side.allCases.count)
    }

    @Test("Partition clones are excluded from PostgreSQL 11 on, where conparentid exists")
    func partitionCloneGateFollowsServerVersion() {
        #expect(!PostgreSQLCatalogForeignKeys.excludesPartitionClones(serverVersionNumber: 0))
        #expect(!PostgreSQLCatalogForeignKeys.excludesPartitionClones(serverVersionNumber: 80_002))
        #expect(!PostgreSQLCatalogForeignKeys.excludesPartitionClones(serverVersionNumber: 100_021))
        #expect(PostgreSQLCatalogForeignKeys.excludesPartitionClones(serverVersionNumber: 110_016))
        #expect(PostgreSQLCatalogForeignKeys.excludesPartitionClones(serverVersionNumber: 170_011))
    }

    @Test("A server without conparentid is never sent the clone filter")
    func cloneFilterOmittedWhenUnsupported() {
        let filtered = PostgreSQLCatalogForeignKeys.query(
            schemaLiteral: "'public'",
            tableLiteral: "'t'",
            excludesPartitionClones: true
        )
        let plain = PostgreSQLCatalogForeignKeys.query(
            schemaLiteral: "'public'",
            tableLiteral: "'t'",
            excludesPartitionClones: false
        )
        #expect(filtered.contains("parent.oid = c.conparentid"))
        #expect(filtered.contains("parent.conrelid = c.conrelid"))
        #expect(!plain.contains("conparentid"))
    }
}
