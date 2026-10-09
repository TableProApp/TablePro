//
//  MongoScriptReadEnforcementTests.swift
//  TableProTests
//

import Foundation
import JavaScriptCore
import Testing

@testable import TablePro

/// The grammar that proves a MongoDB statement a read and the plugin host's read policy are two lists
/// kept by hand. Each read runs through the real prelude against a host held to the policy, so a read
/// the grammar accepts and the host would refuse fails here rather than at every Safe Mode level.
struct MongoScriptReadEnforcementTests {
    private typealias RecordingHost = MongoScriptPreludeTests.RecordingHost

    /// The reads `QueryClassifierMongoDBTests` pins, copied.
    private static let classifierReads: [String] = [
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

    private static let appWrittenReads: [String] = [
        #"db.c.find({_id: LegacyJavaUUID("0e3b0c1e-6c8f-4c1a-9a0e-2f1c3d4e5f60")})"#,
        #"db.c.find({_id: CSUUID("0e3b0c1e-6c8f-4c1a-9a0e-2f1c3d4e5f60")})"#,
        #"db.c.find({ref: DBRef("users", ObjectId("507f1f77bcf86cd799439011"))})"#,
        #"db.c.find({s: BSONSymbol("x")})"#,
        "db.c.find({v: NaN})",
        "db.c.find({v: {$in: [Infinity, -Infinity]}})",
        #"db.c.find({at: new Date(1700000000000), b: BinData(4, "AAAA"), t: Timestamp(1, 2)})"#
    ]

    private static let literalShapes = """
        db.events.find({
            _id: ObjectId("507f1f77bcf86cd799439011"),
            at: {$gte: ISODate("2024-01-01T00:00:00Z"), $lt: new Date("2025-01-01")},
            n: NumberLong("5"), d: NumberDecimal("1.5"), i: NumberInt(3), u: UUID("0e3b0c1e-6c8f-4c1a-9a0e-2f1c3d4e5f60"),
            r: /^ab[/]c\\/d/i, low: MinKey, high: MaxKey(), ratio: -0.5e-3, none: null, ok: true,
            name: "caf\\u00e9 \\"quoted\\" \\uD83D\\uDE00", single: 'it\\'s', 1: [1, 2, [3, {x: false}],]
        })
        """

    /// A call for every name the grammar proves a read that the reads above leave out.
    private static let grammarReads: [String] = [
        "db.getCollectionInfos()",
        "db.version()",
        "db.serverStatus()",
        "db.hostInfo()",
        "db.currentOp()",
        "db.getName()",
        "db.getMongo().getDB(\"reporting\").stats()",
        "db.users.count({a: 1})",
        "db.users.getIndices()",
        "db.users.stats()",
        "db.users.dataSize()",
        "db.users.storageSize()",
        "db.users.totalIndexSize()",
        "db.users.totalSize()",
        "db.users.isCapped()",
        "db.users.getName()",
        "db.users.getFullName()",
        "db.users.find({}).projection({a: 1}).collation({locale: \"fr\"}).hint({a: 1}).maxTimeMS(100).allowDiskUse().toArray()",
        "db.users.find({}).size()",
        "db.users.find({}).count()",
        "db.users.find({}).next()",
        "db.users.find({}).hasNext()",
        "db.users.find({}).tryNext()",
        "db.users.find({}).isExhausted()",
        "db.users.find({}).objsLeftInBatch()",
        "db.users.aggregate([{$match: {}}]).count()",
        "db.users.aggregate([{$match: {}}]).explain()",
        "db.users.explain().find({a: 1})",
        "db.users.explain(\"queryPlanner\").count({a: 1})",
        "db.c.find({h: HexData(0, \"00ff\")})",
        "db.inventory.aggregate([{$group: {_id: \"$out\", n: {$sum: 1}}}])",
        "db.c.aggregate([{$project: {m: \"$merge\"}}])",
        "show databases",
        "show tables"
    ]

    /// Shaped like the host's answers, so each read runs to its end and every call it makes is seen.
    private static let replies: [String: String] = [
        "openCursor": "1",
        "cursorFetch": #"{"docs": [{"_id": {"$numberInt": "1"}}], "done": true}"#,
        "cursorCount": "1",
        "cursorExplain": #"{"queryPlanner": {}}"#,
        "countDocuments": "1",
        "estimatedDocumentCount": "1",
        "distinct": #"["a"]"#,
        "listCollections": #"["users"]"#,
        "listIndexes": #"[{"v": 2, "key": {"_id": 1}, "name": "_id_"}]"#,
        "collectionStats": #"{"size": 1, "storageSize": 1, "totalIndexSize": 1, "capped": false}"#,
        "command": #"{"ok": 1, "cursor": {"firstBatch": []}, "databases": [], "version": "7.0.0"}"#,
        "hexToBase64": #""AP8=""#,
        "encodeUuid": #"{"base64": "DjsMHmyPTBqaDi8cPU5fYA==", "subtype": 4, "text": "0e3b0c1e-6c8f-4c1a-9a0e-2f1c3d4e5f60"}"#
    ]

    private func makeContext(_ host: RecordingHost) throws -> JSContext {
        try MongoScriptContext.make(execute: { host.handle($0) }, emit: { host.record(printed: $0) })
    }

    private func isRead(_ statement: String) -> Bool {
        QueryClassifier.classifyTier(statement, databaseType: .mongodb) == .safe
    }

    @Test("Every statement the grammar proves a read runs to its end sending only what a read may send")
    func provenReadsStayWithinThePolicy() throws {
        let reads = Self.classifierReads + Self.appWrittenReads + [Self.literalShapes] + Self.grammarReads
        for statement in reads {
            #expect(isRead(statement), "\(statement)")

            let host = RecordingHost()
            host.access = .read
            host.repliesByOp = Self.replies
            let context = try makeContext(host)
            context.evaluateScript(MongoShellCommandLine.rewrite(statement))

            #expect(context.exception == nil, "\(statement): \(context.exception?.toString() ?? "")")
            #expect(host.refused.isEmpty, "\(statement) sent \(host.refused)")
            for opened in host.requests(op: "openCursor") where opened["kind"] as? String == "aggregate" {
                let pipeline = opened["pipeline"] as? String ?? ""
                let options = opened["options"] as? String
                #expect(!MongoScriptAccessPolicy.writes(pipeline: pipeline, options: options), "\(statement)")
            }
        }
    }

    @Test("A read whose find an earlier statement pointed at deleteMany is refused before it deletes")
    func poisonedFindIsRefusedUnderRead() throws {
        let host = RecordingHost()
        let context = try makeContext(host)
        context.evaluateScript("DBCollection.prototype.find = DBCollection.prototype.deleteMany")
        #expect(context.exception == nil)

        let read = "db.c.find({})"
        #expect(isRead(read))
        host.access = .read
        context.evaluateScript(read)

        let delete = try #require(host.requests(op: "delete").first)
        #expect(!MongoScriptAccessPolicy.allows(op: "delete", request: delete, access: .read))
        #expect(host.refused == ["delete"])
        #expect(context.exception?.objectForKeyedSubscript("message")?.toString() == MongoScriptText.refusedUnderRead("delete"))
    }

    @Test("The same statement sent as a write still writes")
    func poisonedFindWritesUnderReadWrite() throws {
        let host = RecordingHost()
        host.repliesByOp = ["delete": "{\"n\": 3}"]
        let context = try makeContext(host)
        context.evaluateScript("DBCollection.prototype.find = DBCollection.prototype.deleteMany")
        context.evaluateScript("db.c.find({})")

        #expect(context.exception == nil)
        #expect(host.requests(op: "delete").count == 1)
        #expect(host.refused.isEmpty)
    }

    @Test("A command, a constructor or a shell command an earlier statement redefined cannot write in a read")
    func otherRedefinitionsAreRefusedUnderRead() throws {
        let cases: [(redefinition: String, read: String, refused: String)] = [
            (
                "DB.prototype.stats = function () { return this.runCommand({dropDatabase: 1}); }",
                "db.stats()",
                "dropDatabase"
            ),
            (
                "ObjectId = function () { db.users.drop(); return 1; }",
                #"db.c.find({_id: ObjectId("507f1f77bcf86cd799439011")})"#,
                "dropCollection"
            ),
            (
                #"DB.prototype.getCollectionInfos = function () { return this.runCommand({explain: "#
                    + #"{aggregate: "c", pipeline: [{$merge: {into: "x"}}], cursor: {}}, verbosity: "executionStats"}); }"#,
                "db.getCollectionInfos()",
                "explain"
            ),
            (
                "show = function () { return db.users.insertOne({a: 1}); }",
                "show collections",
                "insertOne"
            )
        ]
        for (redefinition, read, refused) in cases {
            let host = RecordingHost()
            let context = try makeContext(host)
            context.evaluateScript(redefinition)
            #expect(context.exception == nil, "\(redefinition)")

            #expect(isRead(read), "\(read)")
            host.access = .read
            context.evaluateScript(MongoShellCommandLine.rewrite(read))

            #expect(host.refused.count == 1, "\(read)")
            #expect(
                context.exception?.objectForKeyedSubscript("message")?.toString()
                    == MongoScriptText.refusedUnderRead(refused),
                "\(read)"
            )
        }
    }
}
