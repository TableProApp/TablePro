//
//  EditModeDataCommandsLanguageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct EditModeDataCommandsLanguageTests {
    private func statement(_ sql: String, databaseType: DatabaseType) -> ExternalStatementGate.Statement {
        ExternalStatementGate.Statement(
            sql: sql,
            connectionId: UUID(),
            databaseType: databaseType,
            externalAccess: .readWrite,
            loadsExtensions: false,
            allowsDestructive: false,
            allowsMultiStatement: false,
            destructiveAlternative: nil,
            allowsOnlyDataStatements: true
        )
    }

    private func refusal(_ statement: ExternalStatementGate.Statement) -> ExternalStatementGateError? {
        do {
            _ = try ExternalStatementGate.classify(statement)
            return nil
        } catch let error as ExternalStatementGateError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - MongoDB

    @Test("Edit refuses a MongoDB session, schema, cursor or server command, and a command it cannot name", arguments: [
        "use admin",
        "db.orders.createIndex({a: 1})",
        #"db.createCollection("x")"#,
        #"db.createView("v", "orders", [])"#,
        #"db.orders.hideIndex("a_1")"#,
        #"db.runCommand({collMod: "orders", validator: {}})"#,
        #"db.runCommand({create: "x"})"#,
        #"db.runCommand({killCursors: "orders", cursors: []})"#,
        #"db.runCommand({validate: "orders", repair: true})"#,
        "db.killOp(123)",
        "sleep(1000)",
        #"db.orders[("insert" + "One")]({a: 1})"#,
        "db.runCommand({insert: 1, documents: []})"
    ])
    func mongoNonDataRefused(sql: String) {
        #expect(refusal(statement(sql, databaseType: .mongodb)) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit refuses a MongoDB write into admin, config, local or a system collection", arguments: [
        #"db.getSiblingDB("admin").getCollection("system.users").insertOne({user: "x"})"#,
        #"db.getSiblingDB("config").settings.updateOne({_id: "chunksize"}, {$set: {value: 1}}, {upsert: true})"#,
        #"db.getCollection("system.js").insertOne({_id: "f"})"#,
        #"db.getSiblingDB("local").startup_log.insertOne({a: 1})"#,
        #"db.getMongo().getDB("Admin").orders.insertOne({a: 1})"#,
        #"db.adminCommand({insert: "system.version", documents: [{}]})"#,
        #"db.adminCommand({insert: "orders", documents: [{a: 1}]})"#,
        #"db.runCommand({update: "settings", updates: [{q: {_id: 1}, u: {$set: {a: 1}}}], $db: "config"})"#,
        #"db.runCommand({insert: "orders", documents: [{a: 1}], insert: "system.js"})"#
    ])
    func mongoSystemWriteRefused(sql: String) {
        #expect(refusal(statement(sql, databaseType: .mongodb)) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit runs MongoDB reads and data changes", arguments: [
        "db.orders.find({a: 1}).limit(5)",
        "db.orders.aggregate([{$match: {}}])",
        "show collections",
        "db.orders.insertOne({a: 1})",
        "db.orders.insertMany([{a: 1}])",
        "db.orders.updateOne({_id: 1}, {$set: {a: 2}})",
        "db.orders.updateMany({a: 1}, {$set: {b: 1}})",
        "db.orders.replaceOne({_id: 1}, {a: 3})",
        "db.orders.deleteOne({_id: 1})",
        "db.orders.findOneAndUpdate({_id: 1}, {$inc: {n: 1}})",
        "db.orders.bulkWrite([{insertOne: {document: {a: 1}}}])",
        #"db.getSiblingDB("shop").orders.insertOne({a: 1})"#,
        #"db.getSiblingDB("admin").getCollection("system.users").find({})"#,
        #"db.runCommand({insert: "orders", documents: [{a: 1}]})"#,
        #"db.runCommand({findAndModify: "orders", query: {_id: 1}, update: {$set: {a: 1}}})"#,
        #"db.runCommand({find: "orders"})"#,
        #"db.runCommand({listCollections: 1})"#
    ])
    func mongoDataPasses(sql: String) {
        #expect(refusal(statement(sql, databaseType: .mongodb)) == nil)
    }

    @Test("MongoDB data calls are named in mongosh notation and commands by their command name")
    func mongoNames() {
        #expect(QueryClassifier.mongoDataCommands("db.orders.insertOne({a: 1})", systemDatabases: [])
            == [DataCommand.named("db.collection.insertOne")])
        #expect(QueryClassifier.mongoDataCommands(#"db["orders"].updateMany({}, {$set: {a: 1}})"#, systemDatabases: [])
            == [DataCommand.named("db.collection.updateMany")])
        #expect(QueryClassifier.mongoDataCommands(#"db.runCommand({insert: "orders"})"#, systemDatabases: [])
            == [DataCommand.named("insert")])
        #expect(QueryClassifier.mongoDataCommands("db.orders.find({}).limit(1)", systemDatabases: [])
            == [DataCommand.read, .read])
        #expect(QueryClassifier.mongoDataCommands("db.orders.find(", systemDatabases: []) == nil)
    }

    // MARK: - Neo4j

    @Test("Edit refuses Cypher schema, privilege, database, transaction and server commands", arguments: [
        "CREATE INDEX person_name FOR (n:Person) ON (n.name)",
        "CREATE CONSTRAINT c FOR (n:Person) REQUIRE n.id IS UNIQUE",
        "CREATE USER bob SET PASSWORD 'secret' CHANGE NOT REQUIRED",
        "GRANT ROLE admin TO bob",
        "ALTER USER bob SET PASSWORD 'x'",
        "CREATE DATABASE other",
        "CREATE OR REPLACE ALIAS a FOR DATABASE neo4j",
        "ALTER DATABASE neo4j SET ACCESS READ ONLY",
        "START DATABASE neo4j",
        "SHOW TRANSACTIONS YIELD transactionId AS id TERMINATE TRANSACTIONS id",
        "ALTER CURRENT GRAPH TYPE SET {(p:Person => {name :: STRING})}",
        "USE system CREATE USER x SET PASSWORD 'y'",
        "CYPHER 25 CREATE INDEX i FOR (n:N) ON (n.x)",
        "EXPLAIN CREATE CONSTRAINT c FOR (n:N) REQUIRE n.x IS UNIQUE",
        "MERGE (n:N {id: 1}) ON CREATE INDEX i FOR (m:N) ON (m.x)",
        #"CREATE INDEX i FOR (n:N) ON (n.x)"#
    ])
    func cypherAdministrationRefused(sql: String) {
        #expect(refusal(statement(sql, databaseType: .neo4j)) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit refuses a Cypher procedure that is neither a read nor a listed data change", arguments: [
        "CALL dbms.setConfigValue('db.logs.query.enabled', 'OFF')",
        "CALL tx.setMetaData({app: 'x'})",
        "CALL db.createLabel('X')",
        "CALL `db`.`createLabel`('X')",
        "CALL db.schema.`visualization`()",
        "MATCH (n) CALL apoc.periodic.iterate('MATCH (m) RETURN m', 'SET m.x = 1', {})"
    ])
    func cypherProcedureRefused(sql: String) {
        #expect(refusal(statement(sql, databaseType: .neo4j)) == .denied(ExternalStatementGate.dataStatementRefusal))
    }

    @Test("Edit runs Cypher reads and data changes", arguments: [
        "MATCH (n:Person) RETURN n LIMIT 10",
        "CREATE (n:Person {name: 'a'})",
        "CREATE p = (a:A)-[:R]->(b:B) RETURN p",
        "MERGE (n:Person {id: 1}) ON CREATE SET n.created = timestamp()",
        "MATCH (n:Person {id: 1}) SET n.name = 'b'",
        "MATCH (n:Person {id: 1}) REMOVE n:Temp",
        "MATCH (n:Person {id: 1}) DETACH DELETE n",
        "UNWIND [1, 2] AS i CREATE (:N {i: i})",
        "MATCH (n:N) CALL (n) { SET n.x = 1 } IN TRANSACTIONS",
        "CALL db.labels()",
        "MATCH (d:Doc {id: 1}) CALL db.create.setNodeVectorProperty(d, 'embedding', [0.1, 0.2])",
        "SHOW INDEXES",
        "EXPLAIN MATCH (n) RETURN n",
        "CYPHER 25 runtime=slotted MATCH (n) RETURN n",
        "USE neo4j MATCH (n) RETURN count(n)",
        "USE graph.byName('shop') MATCH (n) RETURN n"
    ])
    func cypherDataPasses(sql: String) {
        #expect(refusal(statement(sql, databaseType: .neo4j)) == nil)
    }

    @Test("Cypher data clauses are named upper case and procedures lower case")
    func cypherNames() {
        #expect(QueryClassifier.cypherDataCommands("MATCH (n {id: 1}) DETACH DELETE n")
            == [DataCommand.named("DETACH DELETE")])
        #expect(QueryClassifier.cypherDataCommands("MERGE (n:N {id: 1}) ON CREATE SET n.x = 1")
            == [DataCommand.named("MERGE"), .named("SET")])
        #expect(QueryClassifier.cypherDataCommands("MATCH (d) CALL db.create.setVectorProperty(d, 'e', [1.0])")
            == [DataCommand.named("db.create.setvectorproperty")])
        #expect(QueryClassifier.cypherDataCommands("MATCH (n) RETURN n") == [DataCommand.read])
    }

    // MARK: - Refused earlier

    @Test("A destructive command is refused as destructive before the data rule reads it", arguments: [
        (DatabaseType.mongodb, #"db.runCommand({createUser: "bob", pwd: "x", roles: []})"#),
        (.mongodb, "db.orders.deleteMany({})"),
        (.neo4j, "DROP INDEX person_name"),
        (.neo4j, "REVOKE ROLE admin FROM bob")
    ])
    func destructiveRefusedFirst(type: DatabaseType, sql: String) {
        #expect(refusal(statement(sql, databaseType: type)) == .denied(ExternalStatementGate.destructiveRefusal))
    }
}
