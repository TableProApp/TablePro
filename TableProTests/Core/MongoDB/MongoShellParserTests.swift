//
//  MongoShellParserTests.swift
//  TableProTests
//
//  Tests for MongoShellParser
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MongoDB Shell Parser")
struct MongoShellParserTests {

    // MARK: - Find Operations

    @Test("find with empty filter")
    func testFindWithEmptyFilter() throws {
        let op = try MongoShellParser.parse("db.users.find({})")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "users")
            #expect(filter == "{}")
            #expect(options.sort == nil)
            #expect(options.skip == nil)
            #expect(options.limit == nil)
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with filter")
    func testFindWithFilter() throws {
        let op = try MongoShellParser.parse("db.users.find({\"name\": \"John\"})")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "users")
            #expect(filter == "{\"name\": \"John\"}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with projection")
    func testFindWithProjection() throws {
        let op = try MongoShellParser.parse("db.users.find({}, {\"name\": 1})")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "users")
            #expect(filter == "{}")
            #expect(options.projection == "{\"name\": 1}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with chained sort, limit, skip")
    func testFindWithChainedOptions() throws {
        let op = try MongoShellParser.parse("db.users.find({}).sort({\"name\": 1}).limit(10).skip(5)")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "users")
            #expect(filter == "{}")
            #expect(options.sort == "{\"name\": 1}")
            #expect(options.limit == 10)
            #expect(options.skip == 5)
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with just limit")
    func testFindWithJustLimit() throws {
        let op = try MongoShellParser.parse("db.users.find({}).limit(100)")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "users")
            #expect(filter == "{}")
            #expect(options.limit == 100)
            #expect(options.sort == nil)
            #expect(options.skip == nil)
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("bare collection reference treated as find all")
    func testBareCollectionAsFindAll() throws {
        let op = try MongoShellParser.parse("db.users")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "users")
            #expect(filter == "{}")
            #expect(options.sort == nil)
            #expect(options.skip == nil)
            #expect(options.limit == nil)
        } else {
            Issue.record("Expected .find operation")
        }
    }

    // MARK: - findOne

    @Test("findOne operation")
    func testFindOne() throws {
        let op = try MongoShellParser.parse("db.users.findOne({\"_id\": \"abc\"})")
        if case .findOne(let collection, let filter) = op {
            #expect(collection == "users")
            #expect(filter == "{\"_id\": \"abc\"}")
        } else {
            Issue.record("Expected .findOne operation")
        }
    }

    // MARK: - Aggregate

    @Test("aggregate operation")
    func testAggregate() throws {
        let op = try MongoShellParser.parse("db.orders.aggregate([{\"$group\": {\"_id\": \"$status\"}}])")
        if case .aggregate(let collection, let pipeline) = op {
            #expect(collection == "orders")
            #expect(pipeline == "[{\"$group\": {\"_id\": \"$status\"}}]")
        } else {
            Issue.record("Expected .aggregate operation")
        }
    }

    // MARK: - Count Operations

    @Test("countDocuments operation")
    func testCountDocuments() throws {
        let op = try MongoShellParser.parse("db.users.countDocuments({})")
        if case .countDocuments(let collection, let filter) = op {
            #expect(collection == "users")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .countDocuments operation")
        }
    }

    @Test("count as alias for countDocuments")
    func testCountAlias() throws {
        let op = try MongoShellParser.parse("db.users.count({})")
        if case .countDocuments(let collection, let filter) = op {
            #expect(collection == "users")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .countDocuments operation")
        }
    }

    // MARK: - Write Operations

    @Test("insertOne operation")
    func testInsertOne() throws {
        let op = try MongoShellParser.parse("db.users.insertOne({\"name\": \"John\"})")
        if case .insertOne(let collection, let document) = op {
            #expect(collection == "users")
            #expect(document == "{\"name\": \"John\"}")
        } else {
            Issue.record("Expected .insertOne operation")
        }
    }

    @Test("insertMany operation")
    func testInsertMany() throws {
        let op = try MongoShellParser.parse("db.users.insertMany([{\"name\": \"A\"}, {\"name\": \"B\"}])")
        if case .insertMany(let collection, let documents) = op {
            #expect(collection == "users")
            #expect(documents == "[{\"name\": \"A\"}, {\"name\": \"B\"}]")
        } else {
            Issue.record("Expected .insertMany operation")
        }
    }

    @Test("updateOne operation")
    func testUpdateOne() throws {
        let op = try MongoShellParser.parse("db.users.updateOne({\"_id\": 1}, {\"$set\": {\"name\": \"Jane\"}})")
        if case .updateOne(let collection, let filter, let update) = op {
            #expect(collection == "users")
            #expect(filter == "{\"_id\": 1}")
            #expect(update == "{\"$set\": {\"name\": \"Jane\"}}")
        } else {
            Issue.record("Expected .updateOne operation")
        }
    }

    @Test("updateMany operation")
    func testUpdateMany() throws {
        let op = try MongoShellParser.parse("db.users.updateMany({\"active\": true}, {\"$set\": {\"status\": \"ok\"}})")
        if case .updateMany(let collection, let filter, let update) = op {
            #expect(collection == "users")
            #expect(filter == "{\"active\": true}")
            #expect(update == "{\"$set\": {\"status\": \"ok\"}}")
        } else {
            Issue.record("Expected .updateMany operation")
        }
    }

    @Test("replaceOne operation")
    func testReplaceOne() throws {
        let op = try MongoShellParser.parse("db.users.replaceOne({\"_id\": 1}, {\"name\": \"Jane\"})")
        if case .replaceOne(let collection, let filter, let replacement) = op {
            #expect(collection == "users")
            #expect(filter == "{\"_id\": 1}")
            #expect(replacement == "{\"name\": \"Jane\"}")
        } else {
            Issue.record("Expected .replaceOne operation")
        }
    }

    @Test("deleteOne operation")
    func testDeleteOne() throws {
        let op = try MongoShellParser.parse("db.users.deleteOne({\"_id\": 1})")
        if case .deleteOne(let collection, let filter) = op {
            #expect(collection == "users")
            #expect(filter == "{\"_id\": 1}")
        } else {
            Issue.record("Expected .deleteOne operation")
        }
    }

    @Test("deleteMany operation")
    func testDeleteMany() throws {
        let op = try MongoShellParser.parse("db.users.deleteMany({\"active\": false})")
        if case .deleteMany(let collection, let filter) = op {
            #expect(collection == "users")
            #expect(filter == "{\"active\": false}")
        } else {
            Issue.record("Expected .deleteMany operation")
        }
    }

    // MARK: - FindOneAnd Operations

    @Test("findOneAndUpdate operation")
    func testFindOneAndUpdate() throws {
        let op = try MongoShellParser.parse("db.users.findOneAndUpdate({\"_id\": 1}, {\"$set\": {\"name\": \"Jane\"}})")
        if case .findOneAndUpdate(let collection, let filter, let update) = op {
            #expect(collection == "users")
            #expect(filter == "{\"_id\": 1}")
            #expect(update == "{\"$set\": {\"name\": \"Jane\"}}")
        } else {
            Issue.record("Expected .findOneAndUpdate operation")
        }
    }

    @Test("findOneAndReplace operation")
    func testFindOneAndReplace() throws {
        let op = try MongoShellParser.parse("db.users.findOneAndReplace({\"_id\": 1}, {\"name\": \"Jane\", \"age\": 30})")
        if case .findOneAndReplace(let collection, let filter, let replacement) = op {
            #expect(collection == "users")
            #expect(filter == "{\"_id\": 1}")
            #expect(replacement == "{\"name\": \"Jane\", \"age\": 30}")
        } else {
            Issue.record("Expected .findOneAndReplace operation")
        }
    }

    @Test("findOneAndDelete operation")
    func testFindOneAndDelete() throws {
        let op = try MongoShellParser.parse("db.users.findOneAndDelete({\"_id\": 1})")
        if case .findOneAndDelete(let collection, let filter) = op {
            #expect(collection == "users")
            #expect(filter == "{\"_id\": 1}")
        } else {
            Issue.record("Expected .findOneAndDelete operation")
        }
    }

    // MARK: - Index Operations

    @Test("createIndex with keys only")
    func testCreateIndexKeysOnly() throws {
        let op = try MongoShellParser.parse("db.users.createIndex({\"name\": 1})")
        if case .createIndex(let collection, let keys, let options) = op {
            #expect(collection == "users")
            #expect(keys == "{\"name\": 1}")
            #expect(options == nil)
        } else {
            Issue.record("Expected .createIndex operation")
        }
    }

    @Test("createIndex with options")
    func testCreateIndexWithOptions() throws {
        let op = try MongoShellParser.parse("db.users.createIndex({\"name\": 1}, {\"unique\": true})")
        if case .createIndex(let collection, let keys, let options) = op {
            #expect(collection == "users")
            #expect(keys == "{\"name\": 1}")
            #expect(options == "{\"unique\": true}")
        } else {
            Issue.record("Expected .createIndex operation")
        }
    }

    @Test("dropIndex operation")
    func testDropIndex() throws {
        let op = try MongoShellParser.parse("db.users.dropIndex(\"name_1\")")
        if case .dropIndex(let collection, let indexName) = op {
            #expect(collection == "users")
            #expect(indexName == "\"name_1\"")
        } else {
            Issue.record("Expected .dropIndex operation")
        }
    }

    // MARK: - Other Operations

    @Test("drop collection")
    func testDropCollection() throws {
        let op = try MongoShellParser.parse("db.users.drop()")
        if case .drop(let collection) = op {
            #expect(collection == "users")
        } else {
            Issue.record("Expected .drop operation")
        }
    }

    @Test("runCommand")
    func testRunCommand() throws {
        let op = try MongoShellParser.parse("db.runCommand({\"ping\": 1})")
        if case .runCommand(let command) = op {
            #expect(command == "{\"ping\": 1}")
        } else {
            Issue.record("Expected .runCommand operation")
        }
    }

    @Test("adminCommand")
    func testAdminCommand() throws {
        let op = try MongoShellParser.parse("db.adminCommand({\"ping\": 1})")
        if case .runCommand(let command) = op {
            #expect(command == "{\"ping\": 1}")
        } else {
            Issue.record("Expected .runCommand operation")
        }
    }

    @Test("raw JSON as runCommand")
    func testRawJsonAsRunCommand() throws {
        let op = try MongoShellParser.parse("{\"ping\": 1}")
        if case .runCommand(let command) = op {
            #expect(command == "{\"ping\": 1}")
        } else {
            Issue.record("Expected .runCommand operation")
        }
    }

    @Test("show dbs")
    func testShowDbs() throws {
        let op = try MongoShellParser.parse("show dbs")
        if case .listDatabases = op {
            // pass
        } else {
            Issue.record("Expected .listDatabases operation")
        }
    }

    @Test("show databases")
    func testShowDatabases() throws {
        let op = try MongoShellParser.parse("show databases")
        if case .listDatabases = op {
            // pass
        } else {
            Issue.record("Expected .listDatabases operation")
        }
    }

    @Test("show collections")
    func testShowCollections() throws {
        let op = try MongoShellParser.parse("show collections")
        if case .listCollections = op {
            // pass
        } else {
            Issue.record("Expected .listCollections operation")
        }
    }

    @Test("show tables")
    func testShowTables() throws {
        let op = try MongoShellParser.parse("show tables")
        if case .listCollections = op {
            // pass
        } else {
            Issue.record("Expected .listCollections operation")
        }
    }

    // MARK: - Database-Level Methods

    @Test("db.getCollectionNames() returns listCollections")
    func testGetCollectionNames() throws {
        let op = try MongoShellParser.parse("db.getCollectionNames()")
        if case .listCollections = op {
            // pass
        } else {
            Issue.record("Expected .listCollections operation")
        }
    }

    @Test("db.listCollections() returns listCollections")
    func testDbListCollections() throws {
        let op = try MongoShellParser.parse("db.listCollections()")
        if case .listCollections = op {
            // pass
        } else {
            Issue.record("Expected .listCollections operation")
        }
    }

    @Test("db.createCollection creates collection via runCommand")
    func testCreateCollection() throws {
        let op = try MongoShellParser.parse("db.createCollection(\"myCollection\")")
        if case .runCommand(let command) = op {
            #expect(command == "{ \"create\": \"myCollection\" }")
        } else {
            Issue.record("Expected .runCommand operation")
        }
    }

    @Test("db.createCollection with single quotes")
    func testCreateCollectionSingleQuotes() throws {
        let op = try MongoShellParser.parse("db.createCollection('myCollection')")
        if case .runCommand(let command) = op {
            #expect(command == "{ \"create\": \"myCollection\" }")
        } else {
            Issue.record("Expected .runCommand operation")
        }
    }

    @Test("db.createCollection with no argument throws missingArgument")
    func testCreateCollectionNoArg() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.createCollection()")
        }
    }

    @Test("db.dropDatabase() returns runCommand with dropDatabase")
    func testDropDatabase() throws {
        let op = try MongoShellParser.parse("db.dropDatabase()")
        if case .runCommand(let command) = op {
            #expect(command == "{ \"dropDatabase\": 1 }")
        } else {
            Issue.record("Expected .runCommand operation")
        }
    }

    @Test("db.version() returns runCommand with buildInfo")
    func testVersion() throws {
        let op = try MongoShellParser.parse("db.version()")
        if case .runCommand(let command) = op {
            #expect(command == "{ \"buildInfo\": 1 }")
        } else {
            Issue.record("Expected .runCommand operation")
        }
    }

    @Test("db.stats() returns runCommand with dbStats")
    func testStats() throws {
        let op = try MongoShellParser.parse("db.stats()")
        if case .runCommand(let command) = op {
            #expect(command == "{ \"dbStats\": 1 }")
        } else {
            Issue.record("Expected .runCommand operation")
        }
    }

    @Test("unknown db-level method throws unsupportedMethod")
    func testUnknownDbLevelMethod() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.unknownDbMethod()")
        }
    }

    // MARK: - Additional Find Operations

    @Test("find with no arguments returns all documents")
    func testFindNoArguments() throws {
        let op = try MongoShellParser.parse("db.collection.find()")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "collection")
            #expect(filter == "{}")
            #expect(options.projection == nil)
            #expect(options.sort == nil)
            #expect(options.limit == nil)
            #expect(options.skip == nil)
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with unquoted key filter")
    func testFindWithUnquotedKeyFilter() throws {
        let op = try MongoShellParser.parse("db.collection.find({name: \"test\"})")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "collection")
            #expect(filter == "{name: \"test\"}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with projection using unquoted keys")
    func testFindWithUnquotedProjection() throws {
        let op = try MongoShellParser.parse("db.collection.find({}, {name: 1})")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "collection")
            #expect(filter == "{}")
            #expect(options.projection == "{name: 1}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    // MARK: - Additional findOne Operations

    @Test("findOne with empty filter")
    func testFindOneEmptyFilter() throws {
        let op = try MongoShellParser.parse("db.collection.findOne({})")
        if case .findOne(let collection, let filter) = op {
            #expect(collection == "collection")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .findOne operation")
        }
    }

    // MARK: - Additional Aggregate Operations

    @Test("aggregate with $match stage")
    func testAggregateWithMatch() throws {
        let op = try MongoShellParser.parse("db.collection.aggregate([{$match: {}}])")
        if case .aggregate(let collection, let pipeline) = op {
            #expect(collection == "collection")
            #expect(pipeline == "[{$match: {}}]")
        } else {
            Issue.record("Expected .aggregate operation")
        }
    }

    // MARK: - Additional Chained Method Operations

    @Test("find with just sort")
    func testFindWithJustSort() throws {
        let op = try MongoShellParser.parse("db.collection.find().sort({a: 1})")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "collection")
            #expect(filter == "{}")
            #expect(options.sort == "{a: 1}")
            #expect(options.limit == nil)
            #expect(options.skip == nil)
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with just skip")
    func testFindWithJustSkip() throws {
        let op = try MongoShellParser.parse("db.collection.find().skip(5)")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "collection")
            #expect(filter == "{}")
            #expect(options.skip == 5)
            #expect(options.sort == nil)
            #expect(options.limit == nil)
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with filter and all chained options")
    func testFindWithFilterAndAllChained() throws {
        let op = try MongoShellParser.parse("db.collection.find({}).sort({a:1}).limit(10).skip(5)")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "collection")
            #expect(filter == "{}")
            #expect(options.sort == "{a:1}")
            #expect(options.limit == 10)
            #expect(options.skip == 5)
        } else {
            Issue.record("Expected .find operation")
        }
    }

    // MARK: - Dotted Collection Names

    @Test("dotted collection name with find")
    func testDottedCollectionFind() throws {
        let op = try MongoShellParser.parse("db.system.version.find()")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "system.version")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("dotted collection name with find and filter")
    func testDottedCollectionFindWithFilter() throws {
        let op = try MongoShellParser.parse("db.system.profile.find({})")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "system.profile")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("dotted collection name with chained methods")
    func testDottedCollectionWithChained() throws {
        let op = try MongoShellParser.parse("db.system.version.find().sort({a:1})")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "system.version")
            #expect(filter == "{}")
            #expect(options.sort == "{a:1}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("bare dotted collection name treated as find all")
    func testBareDottedCollection() throws {
        let op = try MongoShellParser.parse("db.system.version")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "system.version")
            #expect(filter == "{}")
            #expect(options.sort == nil)
            #expect(options.limit == nil)
            #expect(options.skip == nil)
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("multiple dots in collection name")
    func testMultipleDottedCollectionName() throws {
        let op = try MongoShellParser.parse("db.a.b.c.find()")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "a.b.c")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("dotted collection with deleteMany")
    func testDottedCollectionDeleteMany() throws {
        let op = try MongoShellParser.parse("db.system.profile.deleteMany({})")
        if case .deleteMany(let collection, let filter) = op {
            #expect(collection == "system.profile")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .deleteMany operation")
        }
    }

    @Test("dotted collection with insertOne")
    func testDottedCollectionInsertOne() throws {
        let op = try MongoShellParser.parse("db.my.collection.insertOne({\"a\": 1})")
        if case .insertOne(let collection, let document) = op {
            #expect(collection == "my.collection")
            #expect(document == "{\"a\": 1}")
        } else {
            Issue.record("Expected .insertOne operation")
        }
    }

    @Test("dotted collection with countDocuments")
    func testDottedCollectionCountDocuments() throws {
        let op = try MongoShellParser.parse("db.system.users.countDocuments({})")
        if case .countDocuments(let collection, let filter) = op {
            #expect(collection == "system.users")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .countDocuments operation")
        }
    }

    @Test("dotted collection with drop")
    func testDottedCollectionDrop() throws {
        let op = try MongoShellParser.parse("db.system.profile.drop()")
        if case .drop(let collection) = op {
            #expect(collection == "system.profile")
        } else {
            Issue.record("Expected .drop operation")
        }
    }

    // MARK: - Bracket Notation for Collections

    @Test("bracket notation with dotted collection name and find")
    func testBracketNotationDottedFind() throws {
        let op = try MongoShellParser.parse("db[\"system.version\"].find()")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "system.version")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("bracket notation with deleteMany")
    func testBracketNotationDeleteMany() throws {
        let op = try MongoShellParser.parse("db[\"my.collection\"].deleteMany({})")
        if case .deleteMany(let collection, let filter) = op {
            #expect(collection == "my.collection")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .deleteMany operation")
        }
    }

    @Test("bracket notation with simple collection name")
    func testBracketNotationSimpleName() throws {
        let op = try MongoShellParser.parse("db[\"collection\"].find()")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "collection")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("bracket notation with single quotes")
    func testBracketNotationSingleQuotes() throws {
        let op = try MongoShellParser.parse("db['my.collection'].find({})")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "my.collection")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("bracket notation bare reference treated as find all")
    func testBracketNotationBareReference() throws {
        let op = try MongoShellParser.parse("db[\"my.collection\"]")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "my.collection")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("bracket notation with chained methods")
    func testBracketNotationChained() throws {
        let op = try MongoShellParser.parse("db[\"my.collection\"].find({}).sort({a: 1}).limit(10)")
        if case .find(let collection, let filter, let options) = op {
            #expect(collection == "my.collection")
            #expect(filter == "{}")
            #expect(options.sort == "{a: 1}")
            #expect(options.limit == 10)
        } else {
            Issue.record("Expected .find operation")
        }
    }

    // MARK: - Additional Special Commands

    @Test("raw JSON command with unquoted key")
    func testRawJsonUnquotedKey() throws {
        let op = try MongoShellParser.parse("{ping: 1}")
        if case .runCommand(let command) = op {
            #expect(command == "{ping: 1}")
        } else {
            Issue.record("Expected .runCommand operation")
        }
    }

    @Test("runCommand with unquoted key")
    func testRunCommandUnquotedKey() throws {
        let op = try MongoShellParser.parse("db.runCommand({ping: 1})")
        if case .runCommand(let command) = op {
            #expect(command == "{ping: 1}")
        } else {
            Issue.record("Expected .runCommand operation")
        }
    }

    @Test("adminCommand with serverStatus")
    func testAdminCommandServerStatus() throws {
        let op = try MongoShellParser.parse("db.adminCommand({serverStatus: 1})")
        if case .runCommand(let command) = op {
            #expect(command == "{serverStatus: 1}")
        } else {
            Issue.record("Expected .runCommand operation")
        }
    }

    // MARK: - Error Cases

    @Test("empty string throws invalidSyntax")
    func testEmptyStringThrowsInvalidSyntax() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("")
        }
    }

    @Test("whitespace only throws invalidSyntax")
    func testWhitespaceOnlyThrowsInvalidSyntax() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("   ")
        }
    }

    @Test("SQL query throws invalidSyntax")
    func testSqlQueryThrowsInvalidSyntax() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("SELECT * FROM users")
        }
    }

    @Test("unknown method throws unsupportedMethod")
    func testUnknownMethodThrowsUnsupportedMethod() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.users.unknownMethod()")
        }
    }

    @Test("insertOne with no argument throws missingArgument")
    func testInsertOneNoArgThrowsMissingArgument() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.users.insertOne()")
        }
    }

    @Test("updateOne with single argument throws missingArgument")
    func testUpdateOneSingleArgThrowsMissingArgument() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.users.updateOne({\"_id\": 1})")
        }
    }

    @Test("db. with no collection or method throws")
    func testDbDotIncompleteThrows() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.")
        }
    }

    @Test("insertMany with no argument throws missingArgument")
    func testInsertManyNoArgThrows() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.users.insertMany()")
        }
    }

    @Test("updateMany with single argument throws missingArgument")
    func testUpdateManySingleArgThrows() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.users.updateMany({\"active\": true})")
        }
    }

    @Test("replaceOne with single argument throws missingArgument")
    func testReplaceOneSingleArgThrows() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.users.replaceOne({\"_id\": 1})")
        }
    }

    @Test("findOneAndUpdate with single argument throws missingArgument")
    func testFindOneAndUpdateSingleArgThrows() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.users.findOneAndUpdate({\"_id\": 1})")
        }
    }

    @Test("findOneAndReplace with single argument throws missingArgument")
    func testFindOneAndReplaceSingleArgThrows() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.users.findOneAndReplace({\"_id\": 1})")
        }
    }

    // MARK: - Edge Cases with Strings and Nested Objects

    @Test("find with dot inside string argument")
    func testFindWithDotInsideString() throws {
        let op = try MongoShellParser.parse("db.collection.find({name: \"test.value\"})")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "collection")
            #expect(filter == "{name: \"test.value\"}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with parentheses inside string argument")
    func testFindWithParensInsideString() throws {
        let op = try MongoShellParser.parse("db.collection.find({name: \"has(parens)\"})")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "collection")
            #expect(filter == "{name: \"has(parens)\"}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with nested $and operator")
    func testFindWithNestedAndOperator() throws {
        let op = try MongoShellParser.parse("db.collection.find({$and: [{a: 1}, {b: 2}]})")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "collection")
            #expect(filter == "{$and: [{a: 1}, {b: 2}]}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with deeply nested objects")
    func testFindWithDeeplyNestedObjects() throws {
        let op = try MongoShellParser.parse("db.collection.find({\"a\": {\"b\": {\"c\": 1}}})")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "collection")
            #expect(filter == "{\"a\": {\"b\": {\"c\": 1}}}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("updateOne with nested $set and nested objects")
    func testUpdateOneNestedSet() throws {
        let op = try MongoShellParser.parse("db.collection.updateOne({a:1}, {$set: {b:2}})")
        if case .updateOne(let collection, let filter, let update) = op {
            #expect(collection == "collection")
            #expect(filter == "{a:1}")
            #expect(update == "{$set: {b:2}}")
        } else {
            Issue.record("Expected .updateOne operation")
        }
    }

    @Test("updateMany with empty filter and $set")
    func testUpdateManyEmptyFilterSet() throws {
        let op = try MongoShellParser.parse("db.collection.updateMany({}, {$set: {active: true}})")
        if case .updateMany(let collection, let filter, let update) = op {
            #expect(collection == "collection")
            #expect(filter == "{}")
            #expect(update == "{$set: {active: true}}")
        } else {
            Issue.record("Expected .updateMany operation")
        }
    }

    @Test("replaceOne with full replacement document")
    func testReplaceOneFullReplacement() throws {
        let op = try MongoShellParser.parse("db.collection.replaceOne({a:1}, {a:2, b:3})")
        if case .replaceOne(let collection, let filter, let replacement) = op {
            #expect(collection == "collection")
            #expect(filter == "{a:1}")
            #expect(replacement == "{a:2, b:3}")
        } else {
            Issue.record("Expected .replaceOne operation")
        }
    }

    @Test("findOneAndUpdate with $set")
    func testFindOneAndUpdateWithSet() throws {
        let op = try MongoShellParser.parse("db.collection.findOneAndUpdate({a:1}, {$set:{b:2}})")
        if case .findOneAndUpdate(let collection, let filter, let update) = op {
            #expect(collection == "collection")
            #expect(filter == "{a:1}")
            #expect(update == "{$set:{b:2}}")
        } else {
            Issue.record("Expected .findOneAndUpdate operation")
        }
    }

    @Test("findOneAndReplace with replacement")
    func testFindOneAndReplaceWithReplacement() throws {
        let op = try MongoShellParser.parse("db.collection.findOneAndReplace({a:1}, {a:2})")
        if case .findOneAndReplace(let collection, let filter, let replacement) = op {
            #expect(collection == "collection")
            #expect(filter == "{a:1}")
            #expect(replacement == "{a:2}")
        } else {
            Issue.record("Expected .findOneAndReplace operation")
        }
    }

    @Test("findOneAndDelete with filter")
    func testFindOneAndDeleteWithFilter() throws {
        let op = try MongoShellParser.parse("db.collection.findOneAndDelete({a:1})")
        if case .findOneAndDelete(let collection, let filter) = op {
            #expect(collection == "collection")
            #expect(filter == "{a:1}")
        } else {
            Issue.record("Expected .findOneAndDelete operation")
        }
    }

    @Test("deleteMany with empty filter")
    func testDeleteManyEmptyFilter() throws {
        let op = try MongoShellParser.parse("db.collection.deleteMany({})")
        if case .deleteMany(let collection, let filter) = op {
            #expect(collection == "collection")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .deleteMany operation")
        }
    }

    @Test("createIndex with unquoted key")
    func testCreateIndexUnquotedKey() throws {
        let op = try MongoShellParser.parse("db.collection.createIndex({name: 1})")
        if case .createIndex(let collection, let keys, let options) = op {
            #expect(collection == "collection")
            #expect(keys == "{name: 1}")
            #expect(options == nil)
        } else {
            Issue.record("Expected .createIndex operation")
        }
    }

    @Test("dropIndex with string index name")
    func testDropIndexStringName() throws {
        let op = try MongoShellParser.parse("db.collection.dropIndex(\"idx_name\")")
        if case .dropIndex(let collection, let indexName) = op {
            #expect(collection == "collection")
            #expect(indexName == "\"idx_name\"")
        } else {
            Issue.record("Expected .dropIndex operation")
        }
    }

    @Test("find with single-quoted string in filter")
    func testFindWithSingleQuotedString() throws {
        let op = try MongoShellParser.parse("db.collection.find({name: 'test'})")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "collection")
            #expect(filter == "{name: 'test'}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("find with comma inside nested object does not split incorrectly")
    func testFindCommaInsideNestedObject() throws {
        let op = try MongoShellParser.parse("db.collection.find({a: 1, b: 2})")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "collection")
            #expect(filter == "{a: 1, b: 2}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("input with leading and trailing whitespace is trimmed")
    func testInputWithWhitespace() throws {
        let op = try MongoShellParser.parse("  db.users.find({})  ")
        if case .find(let collection, let filter, _) = op {
            #expect(collection == "users")
            #expect(filter == "{}")
        } else {
            Issue.record("Expected .find operation")
        }
    }

    @Test("unmatched parenthesis throws invalidSyntax")
    func testUnmatchedParenthesisThrows() {
        #expect(throws: MongoShellParseError.self) {
            _ = try MongoShellParser.parse("db.users.find({name: \"test\"")
        }
    }

    @Test("deleteOne with filter containing nested array")
    func testDeleteOneNestedArray() throws {
        let op = try MongoShellParser.parse("db.collection.deleteOne({tags: [\"a\", \"b\"]})")
        if case .deleteOne(let collection, let filter) = op {
            #expect(collection == "collection")
            #expect(filter == "{tags: [\"a\", \"b\"]}")
        } else {
            Issue.record("Expected .deleteOne operation")
        }
    }
}
