//
//  SchemaOperationKindTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct SchemaOperationKindTests {
    private func kind(_ sql: String, destructive: Bool, _ type: DatabaseType) -> OperationKind {
        let statement = SchemaStatement(sql: sql, description: "change", isDestructive: destructive)
        return DatabaseManager.schemaOperationKind(for: [statement], combinedSQL: sql, databaseType: type)
    }

    @Test("A removed MongoDB field is destructive, though its statement is an update")
    func removedFieldIsDestructive() {
        let sql = #"db.users.updateMany({"legacy": {"$exists": true}}, {"$unset": {"legacy": ""}});"#
        #expect(kind(sql, destructive: true, .mongodb) == .destructiveQuery)
    }

    @Test("A renamed MongoDB field and the collMod ahead of it stay a schema change")
    func renamedFieldIsNotDestructive() {
        let rename = #"db.users.updateMany({"a": {"$exists": true}, "b": {"$exists": false}}, {"$rename": {"a": "b"}});"#
        let validator = #"db.runCommand({"collMod": "users", "validator": {"$jsonSchema": {}}});"#
        #expect(kind(rename, destructive: false, .mongodb) == .schemaMutation)
        #expect(kind(validator, destructive: false, .mongodb) == .schemaMutation)
    }

    @Test("A SQL DROP COLUMN is destructive from its text, as before")
    func sqlDropColumn() {
        #expect(kind("ALTER TABLE t DROP COLUMN c;", destructive: false, .postgresql) == .destructiveQuery)
        #expect(kind("ALTER TABLE t ADD COLUMN c int;", destructive: false, .postgresql) == .schemaMutation)
    }

    @Test("A SQL column type change is destructive, as the Structure tab already marks it")
    func sqlTypeChange() {
        #expect(kind("ALTER TABLE t ALTER COLUMN c TYPE bigint;", destructive: true, .postgresql) == .destructiveQuery)
    }
}
