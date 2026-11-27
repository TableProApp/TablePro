import Foundation
import TableProSQLGrammar
import Testing

struct MongoStatementParserTests {
    private func calls(_ text: String) -> [MongoStatement.Call] {
        MongoStatementParser.parse(text) { _ in false }?.calls ?? []
    }

    @Test("A collection call records the collection it reaches and the database the text names", arguments: [
        ("db.orders.insertOne({a: 1})", nil, "orders"),
        (#"db["user-events"].find({})"#, nil, "user-events"),
        (#"db.getCollection("system.js").insertOne({})"#, nil, "system.js"),
        (#"db.getSiblingDB("shop").orders.updateOne({}, {$set: {a: 1}})"#, "shop", "orders"),
        (#"db.getMongo().getDB("shop").getCollection("orders").deleteOne({_id: 1})"#, "shop", "orders"),
        (#"db.getSiblingDB("admin").getSiblingDB("config").settings.updateOne({}, {$set: {a: 1}})"#, "config", "settings")
    ] as [(String, String?, String?)])
    func collectionTargets(text: String, database: String?, collection: String?) throws {
        let call = try #require(calls(text).last)
        #expect(call.receiver == .collection)
        #expect(call.database == database)
        #expect(call.collection == collection)
        #expect(call.commandName == nil)
    }

    @Test("A cursor or an explain keeps the database and collection it came from")
    func chainedReceivers() {
        let found = calls(#"db.getSiblingDB("shop").orders.find({}).limit(1)"#)
        #expect(found.map { $0.receiver } == [MongoStatement.Receiver.collection, .cursor])
        #expect(found.map { $0.database } == ["shop", "shop"])
        #expect(found.map { $0.collection } == ["orders", "orders"])
        #expect(calls("db.orders.explain().find({})").map { $0.receiver } == [MongoStatement.Receiver.collection, .explainer])
    }

    @Test("A database call reaches no collection", arguments: ["db.stats()", #"db.createCollection("orders")"#, "db.killOp(1)"])
    func databaseCallsReachNoCollection(text: String) throws {
        let call = try #require(calls(text).first)
        #expect(call.receiver == .database)
        #expect(call.collection == nil)
        #expect(call.database == nil)
    }

    @Test("A command's collection is its document's first value, and its database the call's or the document's $db", arguments: [
        (#"db.runCommand({insert: "orders", documents: []})"#, nil, "orders"),
        (#"db.adminCommand({insert: "system.version", documents: []})"#, "admin", "system.version"),
        (#"db.getSiblingDB("shop").runCommand({update: "orders", updates: []})"#, "shop", "orders"),
        (#"db.runCommand({update: "settings", updates: [], $db: "config"})"#, "config", "settings"),
        (#"db.adminCommand({insert: "orders", "$db": "shop"})"#, "shop", "orders"),
        (#"db.runCommand({insert: "orders", $db: "shop", $db: "admin"})"#, "admin", "orders"),
        (#"db.runCommand({insert: "orders", documents: [], insert: "system.js"})"#, nil, "system.js"),
        (#"db.runCommand({insert: "orders", insert: 1})"#, nil, nil),
        ("db.runCommand({insert: 1})", nil, nil),
        (#"db.runCommand({insert: {name: "orders"}})"#, nil, nil)
    ] as [(String, String?, String?)])
    func commandTargets(text: String, database: String?, collection: String?) throws {
        let call = try #require(calls(text).first)
        #expect(call.receiver == .database)
        #expect(call.database == database)
        #expect(call.collection == collection)
    }

    @Test("A command is named by its document's first key, and a document-less call names none")
    func commandNames() {
        #expect(calls(#"db.runCommand({findAndModify: "orders", query: {}})"#).first?.commandName == "findAndModify")
        #expect(calls(#"db.runCommand({a: {toEJSON: MinKey}, insert: "orders"})"#).first?.commandName == "a")
        #expect(calls(#"db.runCommand("insert")"#).first?.commandName == nil)
        #expect(calls(#"db.runCommand("insert")"#).first?.collection == nil)
    }

    @Test("use and show are shell calls that read, and use names the database it moves to")
    func shellCommands() throws {
        let use = try #require(calls("use admin").first)
        #expect(use.name == "use")
        #expect(use.receiver == .shell)
        #expect(use.isRead)
        #expect(use.database == "admin")
        let show = try #require(calls("show collections").first)
        #expect(show.name == "show")
        #expect(show.receiver == .shell)
        #expect(show.database == nil)
    }
}
