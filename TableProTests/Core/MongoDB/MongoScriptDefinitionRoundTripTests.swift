//
//  MongoScriptDefinitionRoundTripTests.swift
//  TableProTests
//
//  The catalog fixtures are canonical Extended JSON as libmongoc 1.28 renders it, read from
//  MongoDB 7.0.43.
//

import Foundation
import JavaScriptCore
import Testing

/// Runs the text Show DDL and Edit View Definition write through the real prelude, and compares
/// what reaches the host with the catalog entry it was written from, one BSON type at a time.
/// Written as relaxed Extended JSON, that text sent `NumberLong(1)` and a whole Double back as
/// Int32s, `9007199254740993` as `9007199254740992`, and a view holding a MinKey or a Timestamp
/// as a document the server could not read.
struct MongoScriptDefinitionRoundTripTests {
    private typealias RecordingHost = MongoScriptPreludeTests.RecordingHost

    private static let pipeline = """
        [ { "$match" : { "a" : { "$gte" : { "$numberLong" : "1" } }, "w" : { "$eq" : { "$numberDouble" : "1.0" } }, \
        "big" : { "$eq" : { "$numberLong" : "9007199254740993" } }, "min" : { "$numberLong" : "-9223372036854775808" }, \
        "i" : { "$numberInt" : "7" }, "imin" : { "$numberInt" : "-2147483648" }, \
        "dec" : { "$numberDecimal" : "1.50" }, "decnan" : { "$numberDecimal" : "NaN" }, \
        "f" : { "$numberDouble" : "2.5" }, "tenth" : { "$numberDouble" : "0.10000000000000000555" }, \
        "neg0" : { "$numberDouble" : "-0.0" }, "bigd" : { "$numberDouble" : "1e+20" }, \
        "wide" : { "$numberDouble" : "9007199254740992.0" }, \
        "inf" : { "$numberDouble" : "Infinity" }, "ninf" : { "$numberDouble" : "-Infinity" }, \
        "nan" : { "$numberDouble" : "NaN" }, \
        "when" : { "$date" : { "$numberLong" : "1577934245678" } }, \
        "reform" : { "$date" : { "$numberLong" : "-12219292800001" } }, \
        "first" : { "$date" : { "$numberLong" : "-62135596800000" } }, \
        "old" : { "$date" : { "$numberLong" : "-62198755200000" } }, \
        "late" : { "$date" : { "$numberLong" : "253402300800000" } }, \
        "decinf" : { "$numberDecimal" : "-Infinity" }, "sym" : { "$symbol" : "q" }, \
        "__proto__" : { "$numberInt" : "1" }, "inner" : { "__proto__" : { "x" : { "$numberLong" : "3" } } }, \
        "oid" : { "$oid" : "5f1d7a3b2c4e5a6b7c8d9e0f" }, \
        "bin" : { "$binary" : { "base64" : "AAECAwQFBgcICQoLDA0ODw==", "subType" : "04" } }, \
        "user" : { "$binary" : { "base64" : "AAEC", "subType" : "80" } }, \
        "code" : { "$code" : "x", "$scope" : { "y" : { "$numberLong" : "2" } } }, \
        "many" : { "$in" : [ { "$minKey" : 1 }, { "$maxKey" : 1 }, { "$timestamp" : { "t" : 5, "i" : 6 } }, \
        { "$regularExpression" : { "pattern" : "a\\\\/b", "options" : "i" } }, null, true, "s" ] } } }, \
        { "$sort" : { "a" : { "$numberInt" : "1" }, "w" : { "$numberInt" : "-1" } } } ]
        """

    private static let collation = """
        { "locale" : "en", "caseLevel" : false, "strength" : { "$numberInt" : "2" }, "version" : "57.1" }
        """

    private static var view: String {
        """
        { "name" : "typed", "type" : "view", "options" : { "viewOn" : "src", "pipeline" : \(pipeline), \
        "collation" : \(collation) }, "info" : { "readOnly" : true } }
        """
    }

    private static let index = """
        { "v" : { "$numberInt" : "2" }, "key" : { "a" : { "$numberInt" : "1" }, "w" : { "$numberDouble" : "1.0" } }, \
        "name" : "typed_idx", "partialFilterExpression" : { "big" : { "$gt" : { "$numberLong" : "9007199254740993" } }, \
        "w" : { "$gte" : { "$numberDouble" : "1.0" } }, "a" : { "$gt" : { "$numberLong" : "2" } } }, \
        "expireAfterSeconds" : { "$numberLong" : "3600" }, "collation" : \(collation) }
        """

    private func requests(sentBy statement: String) throws -> RecordingHost {
        let host = RecordingHost()
        let context = try MongoScriptContext.make(
            execute: { host.handle($0) },
            emit: { host.record(printed: $0) }
        )
        context.evaluateScript(statement)
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return host
    }

    private func sentCommand(_ statement: String) throws -> String {
        let commands = try requests(sentBy: statement).requests(op: "command")
        #expect(commands.count == 1)
        return try #require(commands.first?["command"] as? String)
    }

    private func member(_ key: String, of json: String) throws -> String {
        try #require(MongoScriptJson.member(of: json, key: key))
    }

    @Test("Edit View Definition sends the pipeline the catalog holds, every value in its own type")
    func collModSendsTheCatalogPipeline() throws {
        let statement = try #require(MongoDBNamespaceEntry(json: Self.view)?.collModStatement())
        let command = try sentCommand(statement)

        #expect(BsonTypedText.of(try member("pipeline", of: command)) == BsonTypedText.of(Self.pipeline))
        #expect(BsonTypedText.of(try member("viewOn", of: command)) == "\"src\"")
    }

    @Test("A view's Show DDL sends the catalog's pipeline and its collation, less the ICU version")
    func createViewSendsTheCatalogPipeline() throws {
        let statement = try #require(MongoDBNamespaceEntry(json: Self.view)?.createViewStatement())
        let command = try sentCommand(statement)

        #expect(BsonTypedText.of(try member("pipeline", of: command)) == BsonTypedText.of(Self.pipeline))
        #expect(BsonTypedText.of(try member("collation", of: command))
            == BsonTypedText.of(MongoDBCollation.portable(Self.collation)))
    }

    @Test("An index's Show DDL builds the spec the catalog holds, every value in its own type")
    func createIndexBuildsTheCatalogSpec() throws {
        let entry = try #require(MongoDBIndexEntry(json: Self.index))
        let host = try requests(sentBy: entry.createIndexStatement(collection: "src"))
        let request = try #require(host.requests(op: "createIndex").first)
        let keys = try #require(request["keys"] as? String)
        let options = try #require(request["options"] as? String)

        let command = MongoScriptCommandBuilder.createIndex(collection: "src", keys: keys, optionsJson: options)
        let indexes = try member("indexes", of: command)
        let spec = try #require(MongoScriptJson.topLevelElements(indexes).first)
        let expected = MongoDBJsonLayout.object([(key: "key", value: entry.keyJson)] + entry.options)
        #expect(BsonTypedText.of(spec) == BsonTypedText.of(expected))
        #expect(expected.contains("\"expireAfterSeconds\" : { \"$numberLong\" : \"3600\" }"))
        #expect(!expected.contains("57.1"))
    }

    @Test("The view's DDL names every value through a constructor mongosh also has, so no wrapper reaches it as a document")
    func definitionsCarryNoWrappers() throws {
        let entry = try #require(MongoDBNamespaceEntry(json: Self.view))
        let statements = [try #require(entry.createViewStatement()), try #require(entry.collModStatement())]
        let wrappers = [
            "$numberInt", "$numberLong", "$numberDouble", "$numberDecimal", "$date", "$oid", "$binary",
            "$timestamp", "$regularExpression", "$symbol", "$minKey", "$maxKey", "$code"
        ]

        for statement in statements {
            for wrapper in wrappers {
                #expect(!statement.contains("\"\(wrapper)\""), "\(wrapper)")
            }
            #expect(statement.contains("[\"__proto__\"]: 1"))
            #expect(statement.contains(#"BSONRegExp("a\\/b", "i")"#))
        }
    }

    @Test("Double keeps a whole value and a negative zero a Double")
    func doubleConstructorSendsADouble() throws {
        let command = try sentCommand("""
            db.runCommand({a: Double(1), b: Double(-0.0), c: Double("2.5"), d: Double(1e21), \
            e: Double(NumberLong("5")), f: Double(NaN), g: Double(-Infinity)})
            """)

        #expect(command == """
            {"a":{"$numberDouble":"1"},"b":{"$numberDouble":"-0.0"},"c":{"$numberDouble":"2.5"},\
            "d":{"$numberDouble":"1e+21"},"e":{"$numberDouble":"5"},"f":{"$numberDouble":"NaN"},\
            "g":{"$numberDouble":"-Infinity"}}
            """)
    }

    @Test("Double reads as its number in arithmetic and refuses text that is not one")
    func doubleConstructorIsANumber() throws {
        let host = RecordingHost()
        let context = try MongoScriptContext.make(execute: { host.handle($0) }, emit: { host.record(printed: $0) })

        #expect(context.evaluateScript("Double(2.5) + 1")?.toDouble() == 3.5)
        #expect(context.evaluateScript("new Double(4) instanceof Double")?.toBool() == true)
        context.evaluateScript("Double(\"abc\")")
        #expect(context.exception?.toString() == "Error: Double takes a number")
    }
}

/// Extended JSON text reduced to what BSON holds: each number and date names its type and value,
/// so `1` and `1.0` differ when they are two types, and `"1"` and `"1.0"` agree when both spell
/// the same Double.
private enum BsonTypedText {
    static func of(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            return "[" + MongoScriptJson.topLevelElements(trimmed).map(of).joined(separator: ",") + "]"
        }
        guard trimmed.hasPrefix("{") else { return trimmed }
        let members = MongoScriptJson.members(of: trimmed)
        if members.count == 1, let typed = typed(members[0]) { return typed }
        return "{" + members.map { "\($0.key):\(of($0.value))" }.joined(separator: ",") + "}"
    }

    private static func typed(_ member: (key: String, value: String)) -> String? {
        let text = MongoScriptJson.decodedString(member.value)
        switch member.key {
        case "$numberInt": return text.map { "int32(\($0))" }
        case "$numberLong": return text.map { "int64(\($0))" }
        case "$numberDouble": return text.flatMap { Double($0) }.map { "double(\($0.bitPattern))" }
        case "$date":
            return MongoScriptJson.member(of: member.value, key: "$numberLong")
                .flatMap(MongoScriptJson.decodedString)
                .map { "date(\($0))" }
        default: return nil
        }
    }
}
