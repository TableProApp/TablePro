//
//  MongoFieldChangeTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

struct MongoFieldChangeTests {
    private func column(_ name: String, _ type: String = "string", nullable: Bool = true) -> PluginColumnDefinition {
        PluginColumnDefinition(name: name, dataType: type, isNullable: nullable)
    }

    private func rename(_ from: String, _ to: String) -> PluginSchemaOperation {
        .modifyColumn(old: column(from), new: column(to))
    }

    private func remove(_ name: String) -> PluginSchemaOperation {
        .dropColumn(column(name))
    }

    @Test("A rename moves the field only where it exists and the new name does not")
    func renameStatement() throws {
        let change = try #require(MongoFieldChange(rename("status", "state")))
        #expect(change.statement(collection: "people", writeConcern: .serverDefault) == """
        db.people.updateMany({"status": {"$exists": true}, "state": {"$exists": false}}, {"$rename": {"status": "state"}})
        """)
    }

    @Test("A removal unsets the field only where it exists")
    func removalStatement() throws {
        let change = try #require(MongoFieldChange(remove("tmp")))
        #expect(change.statement(collection: "people", writeConcern: .serverDefault) == """
        db.people.updateMany({"tmp": {"$exists": true}}, {"$unset": {"tmp": ""}})
        """)
    }

    @Test("A collection a method would shadow is reached through getCollection")
    func shadowedCollectionName() {
        #expect(MongoFieldChange.remove("a").statement(collection: "stats", writeConcern: .serverDefault).hasPrefix("db.getCollection(\"stats\").updateMany("))
        #expect(MongoFieldChange.remove("a").statement(collection: "my orders", writeConcern: .serverDefault).hasPrefix("db.getCollection(\"my orders\")"))
    }

    @Test("Quotes, backslashes, newlines and line separators in a name stay inside their string")
    func namesAreEscaped() {
        let statement = MongoFieldChange.rename(from: "q\"uote", to: "back\\slash\nline\u{2028}").statement(collection: "c", writeConcern: .serverDefault)
        #expect(statement == #"db.c.updateMany({"q\"uote": {"$exists": true}, "back\\slash\nline"# + "\u{2028}"
            + #"": {"$exists": false}}, {"$rename": {"q\"uote": "back\\slash\nline"# + "\u{2028}" + #""}})"#)
    }

    /// `mongoc_client_command_simple` sends a command with no write concern of its own, so a
    /// connection set to `majority` saved with the server's default until the statement named it.
    @Test("The statement carries the connection's write concern, and none when the connection sets none")
    func statementCarriesWriteConcern() {
        let majority = MongoWriteConcern(acknowledgement: .majority, journal: true, timeoutMS: 5_000)
        #expect(MongoFieldChange.rename(from: "a", to: "b").statement(collection: "people", writeConcern: majority) == """
        db.people.updateMany({"a": {"$exists": true}, "b": {"$exists": false}}, {"$rename": {"a": "b"}}, \
        {"writeConcern": {"w": "majority", "j": true, "wtimeout": 5000}})
        """)
        let two = MongoWriteConcern(acknowledgement: .members(2), journal: nil, timeoutMS: nil)
        #expect(MongoFieldChange.remove("tmp").statement(collection: "people", writeConcern: two) == """
        db.people.updateMany({"tmp": {"$exists": true}}, {"$unset": {"tmp": ""}}, {"writeConcern": {"w": 2}})
        """)
        #expect(!MongoFieldChange.remove("tmp").statement(collection: "people", writeConcern: .serverDefault).contains("writeConcern"))
    }

    /// Measured on 7.0.43: an update sent with `w: 0` is answered `n: 0` with no error whatever it
    /// changed, so a save could not tell a finished rename from one that failed.
    @Test("A write concern that asks for no answer is raised to one acknowledgement, and the rest is kept")
    func unacknowledgedConcernIsRaised() {
        #expect(MongoWriteConcern(acknowledgement: .members(0), journal: nil, timeoutMS: 100).schemaChangeJson
            == #"{"w": 1, "wtimeout": 100}"#)
        #expect(MongoWriteConcern(acknowledgement: .members(0), journal: true, timeoutMS: nil).schemaChangeJson
            == #"{"w": 0, "j": true}"#)
        #expect(MongoWriteConcern(acknowledgement: .tag("dc"), journal: false, timeoutMS: 0).schemaChangeJson
            == #"{"w": "dc", "j": false}"#)
        #expect(MongoWriteConcern(acknowledgement: nil, journal: true, timeoutMS: nil).schemaChangeJson == #"{"j": true}"#)
        #expect(MongoWriteConcern.serverDefault.schemaChangeJson == nil)
    }

    /// The session driver keeps a collection's inferred and declared field types by database and
    /// collection, and a Structure save runs on another connection, so the save names the
    /// collection and the driver drops it wherever it keeps it.
    @Test("A collection's cache keys are found in every database, and no other collection's")
    func collectionCacheKeys() {
        let key = MongoCollectionCacheKey.key(database: "shop", collection: "orders")
        #expect(MongoCollectionCacheKey.names(key, collection: "orders"))
        #expect(MongoCollectionCacheKey.names(MongoCollectionCacheKey.key(database: "archive", collection: "orders"), collection: "orders"))
        #expect(!MongoCollectionCacheKey.names(key, collection: "rders"))
        #expect(!MongoCollectionCacheKey.names(MongoCollectionCacheKey.key(database: "shop", collection: "old_orders"), collection: "orders"))
        #expect(!MongoCollectionCacheKey.names(MongoCollectionCacheKey.key(database: "orders", collection: "items"), collection: "orders"))
    }

    @Test("_id cannot be renamed, removed or taken as a new name")
    func identifierIsRefused() {
        #expect(MongoFieldChange.refusal(for: rename("_id", "id")) != nil)
        #expect(MongoFieldChange.refusal(for: remove("_id")) != nil)
        #expect(MongoFieldChange.refusal(for: rename("id", "_id")) != nil)
    }

    @Test("A name an update cannot address is refused on either side of a rename and for a removal")
    func unaddressableNamesAreRefused() {
        for name in ["", "$x", "a.b", "a\u{0}b", "__proto__"] {
            #expect(MongoFieldChange.refusal(for: rename("a", name)) != nil, "rename to \(name.debugDescription)")
            #expect(MongoFieldChange.refusal(for: remove(name)) != nil, "remove \(name.debugDescription)")
        }
        #expect(MongoFieldChange.refusal(for: rename("price.usd", "price")) != nil)
        #expect(MongoFieldChange.refusal(for: rename("a", "1")) == nil)
        #expect(MongoFieldChange.refusal(for: rename("a", "tên mới")) == nil)
    }

    @Test("The $ and dot refusal reads the same as the one New Table gives")
    func sharedAddressingWording() {
        #expect(MongoFieldName.addressingRefusal("a.b") == String(
            format: String(localized: "MongoDB cannot address a field named %@. A field name cannot start with $ or contain a dot."),
            "a.b"
        ))
    }

    @Test("A change to anything but the name is refused, with or without a rename")
    func attributeChangesAreRefused() {
        #expect(MongoFieldChange.refusal(for: .modifyColumn(old: column("a", "string"), new: column("a", "int"))) != nil)
        #expect(MongoFieldChange.refusal(for: .modifyColumn(old: column("a"), new: column("b", "int"))) != nil)
        #expect(MongoFieldChange.refusal(for: .modifyColumn(old: column("a"), new: column("b", nullable: false))) != nil)
        #expect(MongoFieldChange.refusal(for: rename("a", "b")) == nil)
    }

    @Test("An operation that is not a field edit is left to the collection's own refusal")
    func otherOperationsPassThrough() {
        let index = PluginIndexDefinition(name: "ix", columns: ["a"], isUnique: false)
        #expect(MongoFieldChange.refusal(for: .addIndex(index)) == nil)
        #expect(MongoFieldChange.refusal(for: .addColumn(column("_id"))) == nil)
        #expect(MongoFieldChange(.addColumn(column("a"))) == nil)
    }

    @Test("A name used by two edits of one save is refused before anything runs")
    func sharedNamesAreRefused() {
        #expect(MongoFieldChangePlan(operations: [rename("a", "b"), rename("b", "c")]).refusal != nil)
        #expect(MongoFieldChangePlan(operations: [rename("a", "b"), rename("b", "a")]).refusal != nil)
        #expect(MongoFieldChangePlan(operations: [remove("b"), rename("a", "b")]).refusal != nil)
        #expect(MongoFieldChangePlan(operations: [rename("a", "c"), rename("b", "c")]).refusal != nil)
    }

    @Test("Edits that share no name keep both steps in the order their statements run")
    func disjointEditsAreKept() {
        let plan = MongoFieldChangePlan(operations: [remove("c"), rename("a", "b")])
        #expect(plan.refusal == nil)
        #expect(plan.changes == [.remove("c"), .rename(from: "a", to: "b")])
        #expect(plan.renames.map(\.from) == ["a"])
    }

    @Test("A save with no field edit has nothing to plan")
    func noFieldEdits() {
        let index = PluginIndexDefinition(name: "ix", columns: ["a"], isUnique: false)
        #expect(MongoFieldChangePlan(operations: [.addIndex(index)]).isEmpty)
        #expect(MongoFieldChangePlan(operations: [.modifyColumn(old: column("a"), new: column("a", "int"))]).isEmpty)
    }
}
