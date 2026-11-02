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

    @Test("A command known to leave data in place writes", arguments: [
        "db.runCommand({ping: 1})",
        #"db.runCommand({insert: "users", documents: [{a: 1}]})"#,
        #"db.runCommand({"collMod": "users", "validator": {"$jsonSchema": {}}})"#,
        #"db.runCommand({"listCollections": 1, "nameOnly": false})"#,
        #"db.getSiblingDB("admin").runCommand({listDatabases: 1})"#
    ])
    func preservingCommandsWrite(text: String) {
        #expect(tier(text) == .write)
    }

    @Test("Any other command is destructive, under every name the server answers to", arguments: [
        #"db.runCommand({delete: "users", deletes: [{q: {}, limit: 0}]})"#,
        #"db.adminCommand({bulkWrite: 1, ops: [{delete: 0, filter: {}, multi: true}], nsInfo: [{ns: "shop.users"}]})"#,
        #"db.runCommand({dropIndexes: "users", index: "*"})"#,
        #"db.runCommand({deleteIndexes: "users", index: "*"})"#,
        #"db.runCommand({convertToCapped: "users", size: 4096})"#,
        #"db.adminCommand({applyOps: [{op: "c", ns: "shop.$cmd", o: {drop: "users"}}]})"#,
        "db.runCommand({dropAllUsersFromDatabase: 1})",
        "db.runCommand({aCommandOfALaterServer: 1})",
        #"db.adminCommand({"\u212AillOp": 1, op: 1})"#,
        #"db.runCommand("dropDatabase")"#,
        "db.runCommand()"
    ])
    func otherCommandsAreDestructive(text: String) {
        #expect(tier(text) == .destructive)
    }

    @Test("A command named after a member the shell drops when it serializes is destructive")
    func commandBehindASerializationHook() {
        #expect(tier(#"db.runCommand({a: {toEJSON: MinKey}, drop: "users"})"#) == .destructive)
        #expect(tier(#"db.runCommand({a: {toEJSON: MinKey}, mapReduce: "users", map: "f", reduce: "g", out: "x"})"#)
            == .destructive)
    }

    @Test("A command or bulkWrite whose argument the grammar cannot read is destructive", arguments: [
        "db.runCommand({drop: `users`})",
        #"db.runCommand(({drop: "users"}))"#,
        #"var command = {drop: "users"}; db.runCommand(command)"#,
        "db.adminCommand(command)",
        #"db.getSiblingDB("admin")["adminCommand"](command)"#,
        "db.users.bulkWrite(operations)",
        "db.users.bulkWrite([{deleteMany: {filter: {}}}], void 0)",
        #"db.users.bulkWrite([{["delete" + "Many"]: {filter: {}}}])"#,
        #"db.users["bulkWrite"](operations)"#
    ])
    func unreadArgumentsAreDestructive(text: String) {
        #expect(tier(text) == .destructive)
    }

    @Test("A bulkWrite is as destructive as the deletes it holds")
    func bulkWriteDeletes() {
        #expect(tier("db.users.bulkWrite([{deleteMany: {filter: {}}}])") == .destructive)
        #expect(tier(#"db.users.bulkWrite([{insertOne: {document: {a: 1}}}, {"delete\u004dany": {filter: {}}}])"#)
            == .destructive)
        #expect(tier("db.users.bulkWrite([{insertOne: {document: {a: 1}}}, {deleteOne: {filter: {a: 1}}}])") == .write)
        #expect(tier("db.users.insertOne({deleteMany: 1})") == .write)
    }

    @Test("The prelude's own plumbing is never literal data", arguments: [
        #"db.users.__reply("dropCollection", {})"#,
        #"db.users.__delete({}, {}, true, "deleteMany")"#,
        #"db.users.__call("command", {command: "{\"dropDatabase\": 1}"})"#,
        #"db.users.__findAndModify({}, null, null, true, "findOneAndDelete")"#,
        #"db["users"]["__call"]("dropCollection")"#,
        #"db.users.find().__configure("sort", {a: 1})"#,
        #"db.__defineGetter__("users", MinKey)"#
    ])
    func preludePlumbingIsNotParsed(text: String) {
        #expect(MongoStatementParser.parse(text) { _ in false } == nil)
        #expect(tier(text) != .read)
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

    @Test("A TTL or capped size, a user or role change and killOp are destructive", arguments: [
        "db.orders.createIndex({createdAt: 1}, {expireAfterSeconds: 0})",
        #"db.runCommand({collMod: "orders", index: {keyPattern: {createdAt: 1}, expireAfterSeconds: 0}})"#,
        #"db.runCommand({collMod: "orders", cappedSize: 4096})"#,
        #"db.runCommand({grantRolesToUser: "app", roles: ["root"]})"#,
        #"db.runCommand({createUser: "eve", pwd: "x", roles: ["root"]})"#,
        #"db.runCommand({updateUser: "app", pwd: "x"})"#,
        "db.adminCommand({killOp: 1, op: 12})"
    ])
    func expiringAndPrivilegeCommandsAreDestructive(text: String) {
        #expect(MongoStatementClassifier.verdict(text, shadowsCollection: { _ in false }).tier == .destructive)
    }

    @Test("An explain of a mapReduce reaches code")
    func explainedMapReduceReachesCode() {
        let text = #"db.runCommand({explain: {mapReduce: "users", map: "function(){emit(1,1)}", "#
            + #"reduce: "function(k,v){return 1}", out: {inline: 1}}, verbosity: "executionStats"})"#
        #expect(MongoStatementClassifier.verdict(text, shadowsCollection: { _ in false }).reachesCode)
    }

    @Test("An index without a TTL stays an ordinary write")
    func plainIndexWrites() {
        #expect(MongoStatementClassifier.verdict("db.orders.createIndex({createdAt: 1})", shadowsCollection: { _ in false }).tier == .write)
    }
}
