import Foundation
import TableProSQLGrammar
import Testing

struct MongoStatementClassifierTests {
    private func verdict(_ text: String) -> MongoStatementVerdict {
        MongoStatementClassifier.verdict(text) { $0.hasPrefix("__") || ["stats", "getName", "getCollection"].contains($0) }
    }

    private func tier(_ text: String) -> MongoStatementTier {
        verdict(text).tier
    }

    @Test("A statement of literal data reads", arguments: [
        #"db.users.find({status: "open"})"#,
        #"db.users.find({status: "open"}).sort({created: -1}).limit(20)"#,
        #"db.getCollection("stats").countDocuments({})"#,
        #"db.users.aggregate([{$match: {a: 1}}, {$group: {_id: "$b"}}])"#,
        "show collections",
        "use orders",
        "  db.users.findOne({_id: ObjectId(\"64b7f0c2a1b2c3d4e5f60718\")});  \n"
    ])
    func reads(text: String) {
        #expect(verdict(text) == MongoStatementVerdict(tier: .read, reachesCode: false))
    }

    @Test("Blank and comment-only text reads", arguments: ["", "  \n", "// note", "/* note */"])
    func triviaReads(text: String) {
        #expect(verdict(text) == MongoStatementVerdict(tier: .read, reachesCode: false))
    }

    @Test("A call outside the read grammar writes", arguments: [
        "db.users.insertOne({a: 1})",
        "db.users.updateMany({}, {$set: {a: 1}})",
        #"db.users.aggregate([{$match: {}}, {$out: "copy"}])"#,
        #"db.c.find(db.c[("delete" + "Many")]({}))"#,
        "var n = 1",
        "db.stats.find()"
    ])
    func writes(text: String) {
        #expect(tier(text) == .write)
    }

    @Test("Dropping or deleting by name is destructive, however it is spelled", arguments: [
        "db.users.deleteMany({})",
        "db.users.drop()",
        "db.dropDatabase()",
        #"db.runCommand({drop: "users"})"#,
        #"db.users["deleteMany"]({})"#,
        "db.users.dr\\u006fp()",
        "db.users . remove({})"
    ])
    func destructive(text: String) {
        #expect(tier(text) == .destructive)
    }

    @Test("$where and other server-side JavaScript reach code, read or not")
    func reachesCode() {
        #expect(verdict(#"db.users.find({$where: "this.a > 1"})"#) == MongoStatementVerdict(tier: .read, reachesCode: true))
        #expect(verdict(#"db.users.aggregate([{$out: "copy"}])"#) == MongoStatementVerdict(tier: .write, reachesCode: true))
        #expect(verdict(#"db.users.mapReduce(function () {}, function () {}, {out: "x"})"#).reachesCode)
        #expect(verdict(#"db.runCommand({eval: "1"})"#).reachesCode)
        #expect(!verdict(#"db.users.find({where: "this.a > 1"})"#).reachesCode)
    }

    @Test("The server's own operators reach code, the two it rewrites mapReduce into among them", arguments: [
        #"db.users.aggregate([{$project: {e: {$_internalJsEmit: {this: "$$ROOT", eval: "function () {}"}}}}])"#,
        #"db.users.aggregate([{$group: {_id: null, v: {$_internalJsReduce: {data: {k: 1, v: "$a"}, eval: "function () {}"}}}}])"#,
        #"db.users.aggregate([{$project: {e: {"\u0024_internalJsEmit": {this: "$$ROOT", eval: "function () {}"}}}}])"#,
        #"db.users.find({$expr: {$_internalJsEmit: {this: "$$ROOT", eval: "function () {}"}}})"#
    ])
    func internalOperatorsReachCode(text: String) {
        #expect(verdict(text) == MongoStatementVerdict(tier: .read, reachesCode: true))
    }

    @Test("An internal operator reaches code in text the grammar rejects, and only as a key in text it accepts")
    func internalOperatorSpelling() {
        #expect(verdict(#"var p = [{$project: {e: {$_internalJsEmit: {this: "$$ROOT", eval: "function () {}"}}}}]"#)
            == MongoStatementVerdict(tier: .write, reachesCode: true))
        #expect(!verdict(#"db.users.find({_internal: "$_internalJsEmit"})"#).reachesCode)
    }

    @Test("Several statements take the worst tier, and any one reaching code marks the text")
    func worstStatementWins() {
        #expect(tier("db.a.find({})\ndb.b.insertOne({})") == .write)
        #expect(tier("db.a.find({});\ndb.b.drop()\ndb.c.insertOne({})") == .destructive)
        #expect(verdict("db.a.find({});\ndb.b.find({})") == MongoStatementVerdict(tier: .read, reachesCode: false))
        #expect(verdict(#"db.a.find({$where: "1"});"# + "\ndb.b.insertOne({})")
            == MongoStatementVerdict(tier: .write, reachesCode: true))
    }
}
