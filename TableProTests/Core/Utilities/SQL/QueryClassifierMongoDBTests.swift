//
//  QueryClassifierMongoDBTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct QueryClassifierMongoDBTests {
    private func tier(_ statement: String) -> QueryTier {
        QueryClassifier.classifyTier(statement, databaseType: .mongodb)
    }

    private func runsCode(_ statement: String) -> Bool {
        QueryClassifier.reachesFilesystemOrExecutesCode(statement, databaseType: .mongodb)
    }

    @Test(
        "Ordinary reads are reads",
        arguments: [
            #"db.c.aggregate([{"$limit": 1}, {"$project": {"_id": 1}}])"#,
            #"db.c.aggregate([{"$match": {"k": {"$nin": ["x"]}}}])"#,
            #"db.c.aggregate([{"$project": {"m": {"$mergeObjects": [{"a": 1}, {"b": 2}]}}}])"#,
            #"db.c.aggregate([{"$project": {"o": "$outcome"}}])"#,
            #"db.c.aggregate([{"$match": {}}]).toArray()"#,
            #"db.c.find({}, {"_id": 1}).limit(1)"#,
            "db.users.find({a: 1})",
            "db.users.find().sort({a: -1}).skip(10).limit(5).batchSize(100).toArray()",
            "db.users.findOne({_id: 1}, {name: 1})",
            "db.users.countDocuments({active: true})",
            "db.users.distinct(\"city\", {active: true})",
            "db.users.find({tags: {$in: [\"drop\", \"deleteMany\"]}})",
            "db.users.find({\"note\": \"call x.drop() later\"})",
            "db.getCollection(\"user-events\").find({})",
            "db[\"my-coll\"].find()",
            "db.getSiblingDB(\"reporting\").orders.find({}).itcount()",
            "db.getMongo().getDB(\"reporting\").orders.estimatedDocumentCount()",
            "db.getCollectionNames()",
            "db.stats()",
            "db.users.getIndexes()",
            "db.users.find({}).explain(\"executionStats\")",
            "db.users.explain(\"executionStats\").aggregate([{$match: {a: 1}}])",
            "db.users.find({}).pretty();",
            "/* lead */ db.users.find({}) // trail",
            "db.users\n  .find({a: 1})\n  .limit(10)",
            "db . users . find ( { a : 1 , } , )",
            "show dbs",
            "show collections",
            "use reporting",
            "use reporting;"
        ]
    )
    func readsAreSafe(statement: String) {
        #expect(tier(statement) == .safe)
    }

    @Test("Literal values of every shape the shell accepts stay reads")
    func literalShapes() {
        let statement = """
            db.events.find({
                _id: ObjectId("507f1f77bcf86cd799439011"),
                at: {$gte: ISODate("2024-01-01T00:00:00Z"), $lt: new Date("2025-01-01")},
                n: NumberLong("5"), d: NumberDecimal("1.5"), i: NumberInt(3), u: UUID("0e3b0c1e-6c8f-4c1a-9a0e-2f1c3d4e5f60"),
                r: /^ab[/]c\\/d/i, low: MinKey, high: MaxKey(), ratio: -0.5e-3, none: null, ok: true,
                name: "caf\\u00e9 \\"quoted\\" \\uD83D\\uDE00", single: 'it\\'s', 1: [1, 2, [3, {x: false}],]
            })
            """
        #expect(tier(statement) == .safe)
    }

    @Test(
        "Values the app itself writes into statements stay reads",
        arguments: [
            #"db.c.find({_id: LegacyJavaUUID("0e3b0c1e-6c8f-4c1a-9a0e-2f1c3d4e5f60")})"#,
            #"db.c.find({_id: CSUUID("0e3b0c1e-6c8f-4c1a-9a0e-2f1c3d4e5f60")})"#,
            #"db.c.find({ref: DBRef("users", ObjectId("507f1f77bcf86cd799439011"))})"#,
            #"db.c.find({s: BSONSymbol("x")})"#,
            "db.c.find({v: NaN})",
            "db.c.find({v: {$in: [Infinity, -Infinity]}})",
            #"db.c.find({at: new Date(1700000000000), b: BinData(4, "AAAA"), t: Timestamp(1, 2)})"#
        ]
    )
    func appWrittenValuesAreSafe(statement: String) {
        #expect(tier(statement) == .safe)
    }

    @Test(
        "Writes are writes",
        arguments: [
            "db.users.insertOne({a: 1})",
            "db.users.updateMany({}, {$set: {a: 1}})",
            "db.users.aggregate([{$out: 'copy'}])",
            "db.users.aggregate([{$merge: {into: 'copy'}}])",
            #"db.users.aggregate([{"\x24out": "copy"}])"#,
            "db.users.aggregate([{$match: {}}, {$out: 'copy'}]).count()",
            "db.users.validate()",
            "db.runCommand({ping: 1})",
            "db.users.find({}).forEach(function (d) { printjson(d) })",
            "db.users.find({}).map(d => d)",
            "runCommand",
            "show users",
            "use reporting.archive",
            "SELECT 1"
        ]
    )
    func writesAreWrites(statement: String) {
        #expect(tier(statement) != .safe)
    }

    /// JavaScriptCore runs each of these as a write, measured against the shell prelude, and each one
    /// passed as a read when the classifier scanned method names.
    @Test(
        "Code that only looks like a read is never a read",
        arguments: [
            #"db.c.find(db.c[("delete"+"Many")]({}))"#,
            "db.c.find(db.c.deleteMany ({}))",
            #"db.c.find(__tp_exec('{"op":"delete","collection":"c","filter":"{}","multi":true}'))"#,
            #"db.c.find(eval("db.c.dr" + "op()"))"#,
            "db.c.find({get a() { db.c.drop(); return 1 }})",
            "db.c.find({toEJSON: function () { return {} }})",
            "db.c.find({__proto__: {a: 1}})",
            #"db.c.find({"__proto__": {a: 1}})"#,
            "db.c.find({...extra})",
            "db.c.find({[key]: 1})",
            "db.c.find({a: `x`})",
            "db.c.find({a: someVariable})",
            "db.c.find({a: 0x10})",
            "db.c.find({a: 010})",
            "db.c.find({a: 1n})",
            "db.c.find({a: 1_000})",
            "db.c?.find({})",
            #"db.c.\u0066ind({})"#,
            "db.c.find({}) <!-- x",
            "db.c.find({})/* unterminated",
            "db.c.find({})\n(function () {})()",
            "db.c.find({}).limit(1).length",
            "-- x\ndb.c.find({})"
        ]
    )
    func disguisedCodeIsNotSafe(statement: String) {
        #expect(tier(statement) != .safe)
    }

    @Test(
        "Destructive calls are destructive however they are spelled",
        arguments: [
            "db.users.drop()",
            "db.users.drop ()",
            "db.users.deleteMany({})",
            "db.users.remove({})",
            "db.dropDatabase()",
            #"db.runCommand({drop: "users"})"#,
            #"db.users["\x64rop"]()"#,
            "db.users[`drop`]()",
            #"db.users.dr\u006fp()"#,
            "db.users.find({}); db.users.drop()",
            "db.users.find({})\ndb.users.drop()",
            "db.users.find({}) // note\u{2028}db.users.drop()",
            "--NaN+db.users.drop()\ndb.users.find({})",
            "--db.users.drop()"
        ]
    )
    func destructiveCallsAreDestructive(statement: String) {
        #expect(tier(statement) == .destructive)
    }

    @Test("Server-side JavaScript is flagged by its exact key, escaped or not")
    func codeExecutionKeys() {
        #expect(runsCode("db.users.find({$where: 'this.a == 1'})"))
        #expect(runsCode(#"db.users.find({"\u0024where": "this.a == 1"})"#))
        #expect(runsCode("db.users.aggregate([{$group: {_id: 1, v: {$accumulator: {}}}}])"))
        #expect(runsCode("db.users.aggregate([{$out: 'copy'}])"))
        #expect(tier("db.users.find({$where: 'this.a == 1'})") == .safe)
        #expect(!runsCode(#"db.c.aggregate([{"$project": {"m": {"$mergeObjects": [{"a": 1}]}}}])"#))
        #expect(!runsCode(#"db.c.aggregate([{"$project": {"o": "$outcome"}}])"#))
    }

    @Test("A literal nested past the depth limit is refused, not followed")
    func deepNestingIsRefused() {
        let depth = 500
        let statement = "db.c.find(" + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + ")"
        #expect(tier(statement) == .write)
    }

    @Test("A JavaScript delete of a local field is not a dangerous query")
    func javaScriptDeleteIsNotDangerous() {
        #expect(!QueryClassifier.isDangerousQuery("delete d.password", databaseType: .mongodb))
        #expect(QueryClassifier.isDangerousQuery("db.users.remove({})", databaseType: .mongodb))
    }

    @Test("A blank statement is a read")
    func blankIsSafe() {
        #expect(tier("  \n ") == .safe)
    }
}
