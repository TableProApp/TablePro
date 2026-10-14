//
//  PostgreSQLTableRebuildTests.swift
//  TableProTests
//

import Foundation
import Testing

struct PostgreSQLTableRebuildTests {
    private static let capabilities = PostgreSQLCapabilities(serverVersion: 170_011)

    private static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func rebuild() -> PostgreSQLTableRebuild {
        var parts = PostgreSQLTableRebuild()
        parts.columnNames = ["id", "code"]
        parts.columnDefinitions = ["id": "id integer NOT NULL", "code": "code integer"]
        parts.copyableColumns = ["id", "code"]
        parts.tableConstraints = ["CONSTRAINT parent_pkey PRIMARY KEY (id)"]
        parts.indexes = ["CREATE UNIQUE INDEX parent_code_idx ON shop.parent USING btree (code)"]
        parts.outboundForeignKeys = ["CONSTRAINT parent_self_fkey FOREIGN KEY (id) REFERENCES shop.parent(code)"]
        parts.inboundForeignKeyDrops = ["ALTER TABLE shop.child DROP CONSTRAINT child_code_fkey"]
        parts.inboundForeignKeyAdds = [
            "ALTER TABLE shop.child ADD CONSTRAINT child_code_fkey FOREIGN KEY (code) REFERENCES shop.parent(code)"
        ]
        parts.triggers = ["CREATE TRIGGER parent_audit AFTER INSERT ON shop.parent FOR EACH ROW EXECUTE FUNCTION audit()"]
        return parts
    }

    private static func statements(_ parts: PostgreSQLTableRebuild) -> [String] {
        parts.statements(
            table: "parent", schema: "shop", desiredOrder: ["code", "id"], quote: quote, capabilities: capabilities
        )
    }

    private static func position(of needle: String, in statements: [String]) throws -> Int {
        try #require(statements.firstIndex { $0.contains(needle) }, "\(needle) missing from the script")
    }

    @Test("Indexes come back before any foreign key, which may reference a unique index rather than a constraint")
    func indexesPrecedeForeignKeys() throws {
        let statements = Self.statements(Self.rebuild())
        let index = try Self.position(of: "CREATE UNIQUE INDEX parent_code_idx", in: statements)
        let outbound = try Self.position(of: "ADD CONSTRAINT parent_self_fkey", in: statements)
        let inbound = try Self.position(of: "ADD CONSTRAINT child_code_fkey", in: statements)
        #expect(index < outbound)
        #expect(index < inbound)
    }

    @Test("Indexes come back after the old table is gone and after the table's own constraints")
    func indexesFollowTheDropAndTheConstraints() throws {
        let statements = Self.statements(Self.rebuild())
        let index = try Self.position(of: "CREATE UNIQUE INDEX parent_code_idx", in: statements)
        let drop = try Self.position(of: #"DROP TABLE "shop"."parent_tablepro_reorder""#, in: statements)
        let primaryKey = try Self.position(of: "ADD CONSTRAINT parent_pkey", in: statements)
        let trigger = try Self.position(of: "CREATE TRIGGER parent_audit", in: statements)
        #expect(drop < index)
        #expect(primaryKey < index)
        #expect(index < trigger)
    }

    @Test("The rebuilt table declares its columns in the order asked for")
    func columnsFollowTheDesiredOrder() throws {
        let statements = Self.statements(Self.rebuild())
        let create = try #require(statements.first { $0.hasPrefix(#"CREATE TABLE "shop"."parent""#) })
        #expect(create == "CREATE TABLE \"shop\".\"parent\" (\n  code integer,\n  id integer NOT NULL\n)")
    }

    @Test("Invalid indexes are named in the caveats and never recreated")
    func invalidIndexesAreNamed() {
        var parts = Self.rebuild()
        parts.invalidIndexes = ["parent_code_key", "parent_code_idx_ccnew"]
        #expect(parts.caveats.contains { $0.contains("parent_code_key, parent_code_idx_ccnew") })
        #expect(!Self.statements(parts).contains { $0.contains("parent_code_key") })
    }

    @Test("A table with no invalid index adds no caveat for them")
    func noInvalidIndexNoCaveat() {
        let caveats = Self.rebuild().caveats
        #expect(caveats.count == 2)
    }
}
