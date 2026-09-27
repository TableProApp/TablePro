//
//  MQLCollectionDefinitionTests.swift
//  TableProTests
//

import Foundation
import JavaScriptCore
import TableProJavaScriptText
import TableProNumberFormatting
import TableProPluginKit
import Testing

struct MQLCollectionDefinitionTests {
    private typealias IndexFixture = (name: String, key: [String: Any], options: [String])

    private static let rawLineBreaks: Set<Unicode.Scalar> = ["\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"]

    /// The text the MongoDB driver on main writes for Show DDL, built the way it builds it: the
    /// header and the `collMod` name are the name as it is, and the index name sits in quotes as it is.
    private static func driverDDL(
        collection: String,
        capped: String? = nil,
        validator: [String: Any]? = nil,
        indexes: [IndexFixture] = []
    ) -> String {
        var sections = ["// Collection: \(collection)"]
        if let capped { sections.append(capped) }
        if let validator, let json = NumberText.json(from: validator, prettyPrinted: true) {
            sections.append("\n// Validator\ndb.runCommand({\n  \"collMod\": \"\(collection)\",\n  \"validator\": \(json)\n})")
        }
        if !indexes.isEmpty {
            sections.append("\n// Indexes")
            for index in indexes {
                let key = NumberText.json(from: index.key, prettyPrinted: true) ?? "{}"
                let options = (index.options + ["\"name\": \"\(index.name)\""]).joined(separator: ", ")
                sections.append("\(MongoCollectionAccessor.expression(for: collection)).createIndex(\(key), {\(options)})")
            }
        }
        return sections.joined(separator: "\n")
    }

    /// Reading the export's own output back must find every statement again, so the output holds
    /// only the shapes the reader accepts, and no line terminator but the line feeds between lines.
    /// JavaScriptCore checks that it parses, without running it.
    private static func expectAllowlistedShapes(_ script: String, collection: String) {
        #expect(!script.unicodeScalars.contains { rawLineBreaks.contains($0) })
        let reread = MQLCollectionDefinition.script(fromDDL: "// Collection: x\n\(script)", collection: collection)
        #expect(reread == script)

        let context = JSGlobalContextCreate(nil)
        let source = JSStringCreateWithCFString(script as CFString)
        defer {
            JSStringRelease(source)
            JSGlobalContextRelease(context)
        }
        #expect(JSCheckScriptSyntax(context, source, nil, 1, nil))
    }

    @Test("The driver's definition comes back as the same statements, written by the export's rules")
    func driverDefinitionIsRewritten() {
        let ddl = Self.driverDDL(
            collection: "users",
            capped: "// Capped: true, size: 4096",
            validator: ["$jsonSchema": ["bsonType": "object", "required": ["email"]]],
            indexes: [
                (name: "email_1", key: ["email": 1], options: ["\"unique\": true"]),
                (name: "createdAt_1", key: ["createdAt": 1], options: ["\"expireAfterSeconds\": 3600", "\"sparse\": true"])
            ]
        )
        let script = MQLCollectionDefinition.script(fromDDL: ddl, collection: "users")
        #expect(script == """
        // Capped: true, size: 4096

        // Validator
        db.runCommand({
          "collMod": "users",
          "validator": {
            "$jsonSchema": {
              "bsonType": "object",
              "required": [
                "email"
              ]
            }
          }
        });

        // Indexes
        db.users.createIndex({"email": 1}, {"unique": true, "name": "email_1"});
        db.users.createIndex({"createdAt": 1}, {"expireAfterSeconds": 3600, "sparse": true, "name": "createdAt_1"});
        """)
        Self.expectAllowlistedShapes(script, collection: "users")
    }

    @Test("Shell constructors and libbson spacing read back as the same values")
    func typedValuesAreRewritten() {
        let ddl = """
        // Collection: events
        // Time series: { "timeField" : "at" }

        // Validator
        db.runCommand({
          "collMod": "events",
          "validator": {
            "at": { "$gte": ISODate("2026-01-01T00:00:00.000Z") },
            "n": { "$lt": NumberLong("9007199254740993") },
            "ratio": Double(1.0),
            "d": NumberDecimal("1.10"),
            "id": { "$ne": ObjectId("507f1f77bcf86cd799439011") },
            "b": { "$ne": BinData(4, "jNAD60olQySTMoj84toNGg==") },
            "t": { "$ne": Timestamp(1, 2) },
            "k": { "$gt": MinKey(), "$lt": MaxKey() },
            "x": { "$in": [ -1, 2.5e-7, -Infinity, NaN, null, false ] }
          }
        })

        // Indexes
        db.getCollection("events").createIndex({ "at" : -1, "n" : 1 }, { "name" : "at_-1_n_1", "partialFilterExpression" : { "n" : { "$gt" : NumberLong("5") } } })
        """
        let script = MQLCollectionDefinition.script(fromDDL: ddl, collection: "events")
        #expect(script.contains("\"at\": {\n      \"$gte\": ISODate(\"2026-01-01T00:00:00.000Z\")\n    }"))
        #expect(script.contains("\"n\": {\n      \"$lt\": NumberLong(\"9007199254740993\")\n    }"))
        #expect(script.contains("\"ratio\": Double(1.0)"))
        #expect(script.contains("\"b\": {\n      \"$ne\": BinData(4, \"jNAD60olQySTMoj84toNGg==\")\n    }"))
        #expect(script.contains("\"$gt\": MinKey(),\n      \"$lt\": MaxKey()"))
        #expect(script.contains("-1,\n        2.5e-7,\n        -Infinity,\n        NaN,\n        null,\n        false"))
        #expect(script.hasSuffix("""
        db.events.createIndex({"at": -1, "n": 1}, {"name": "at_-1_n_1", "partialFilterExpression": {"n": {"$gt": NumberLong("5")}}});
        """))
        #expect(!script.contains(MQLCollectionDefinition.skippedStatementComment))
        Self.expectAllowlistedShapes(script, collection: "events")
    }

    @Test("A name holding a line terminator stays inside its comment and its string literals")
    func lineTerminatorsInNamesStayInsideLiterals() throws {
        let context = try #require(JSContext())
        let parse = try #require(context.evaluateScript("JSON.parse"))
        for terminator: Unicode.Scalar in ["\u{85}", "\u{2028}", "\u{2029}"] {
            let collection = "a\(String(terminator))b"
            let indexName = "i\(String(terminator))j"
            let ddl = """
            // Collection: \(JavaScriptText.lineComment(collection).dropFirst(3))

            // Indexes
            \(MongoCollectionAccessor.expression(for: collection)).createIndex({"k\(String(terminator))": 1}, {"name": \(JavaScriptText.stringLiteral(indexName))})
            """
            let script = MQLCollectionDefinition.script(fromDDL: ddl, collection: collection)
            let keyName = "k\(String(terminator))"
            #expect(script.contains("db.getCollection(\(JavaScriptText.stringLiteral(collection))).createIndex("))
            for name in [collection, indexName, keyName] {
                let literal = JavaScriptText.stringLiteral(name)
                #expect(script.contains(literal))
                let parsed = parse.call(withArguments: [literal])?.toString()
                #expect(parsed?.unicodeScalars.elementsEqual(name.unicodeScalars) == true)
            }
            Self.expectAllowlistedShapes(script, collection: collection)
        }
    }

    @Test("A header split by a line feed in the name leaves its second line out")
    func headerSplitByLineFeedIsLeftOut() {
        let collection = "a\nb"
        let ddl = Self.driverDDL(collection: collection, indexes: [(name: "k_1", key: ["k": 1], options: [])])
        let script = MQLCollectionDefinition.script(fromDDL: ddl, collection: collection)
        #expect(script == """
        \(MQLCollectionDefinition.skippedStatementComment)

        // Indexes
        db.getCollection("a\\nb").createIndex({"k": 1}, {"name": "k_1"});
        """)
        Self.expectAllowlistedShapes(script, collection: collection)
    }

    @Test("A validator whose collection name was written unescaped is left out, and the indexes kept")
    func unescapedCollModNameIsLeftOut() {
        let collection = "a\"b"
        let ddl = Self.driverDDL(
            collection: collection,
            validator: ["$jsonSchema": ["bsonType": "object"]],
            indexes: [(name: "k_1", key: ["k": 1], options: [])]
        )
        let script = MQLCollectionDefinition.script(fromDDL: ddl, collection: collection)
        #expect(!script.contains("runCommand"))
        #expect(script.contains(MQLCollectionDefinition.skippedStatementComment))
        #expect(script.hasSuffix("db.getCollection(\"a\\\"b\").createIndex({\"k\": 1}, {\"name\": \"k_1\"});"))
        Self.expectAllowlistedShapes(script, collection: collection)
    }

    @Test("An index whose name was written unescaped is left out")
    func unescapedIndexNameIsLeftOut() {
        let ddl = Self.driverDDL(
            collection: "users",
            indexes: [(name: "a\"b", key: ["k": 1], options: []), (name: "email_1", key: ["email": 1], options: [])]
        )
        let script = MQLCollectionDefinition.script(fromDDL: ddl, collection: "users")
        #expect(script == """
        // Indexes
        \(MQLCollectionDefinition.skippedStatementComment)
        db.users.createIndex({"email": 1}, {"name": "email_1"});
        """)
        Self.expectAllowlistedShapes(script, collection: "users")
    }

    @Test("A statement spelled inside an index name that fails to read is left out with it")
    func statementInsideAFailedStatementIsLeftOut() {
        let name = #"x" @ db.runCommand({"collMod": "users", "validator": {"$expr": false}}) @ ""#
        let ddl = Self.driverDDL(
            collection: "users",
            indexes: [(name: name, key: ["k": 1], options: []), (name: "email_1", key: ["email": 1], options: [])]
        )
        let script = MQLCollectionDefinition.script(fromDDL: ddl, collection: "users")
        #expect(script == """
        // Indexes
        \(MQLCollectionDefinition.skippedStatementComment)
        db.users.createIndex({"email": 1}, {"name": "email_1"});
        """)
        Self.expectAllowlistedShapes(script, collection: "users")
    }

    @Test("A validator anywhere but first, where the driver writes it, is left out")
    func validatorAfterAnIndexIsLeftOut() {
        let name = "x\"})\ndb.runCommand({\"collMod\": \"users\", \"validator\": {\"$expr\": false}})\n//"
        let ddl = Self.driverDDL(collection: "users", indexes: [(name: name, key: ["k": 1], options: [])])
        let script = MQLCollectionDefinition.script(fromDDL: ddl, collection: "users")
        #expect(script == """
        // Indexes
        db.users.createIndex({"k": 1}, {"name": "x"});
        \(MQLCollectionDefinition.skippedStatementComment)
        // "})
        """)
        Self.expectAllowlistedShapes(script, collection: "users")
    }

    @Test("A statement that does not start its own line is left out")
    func statementSharingALineIsLeftOut() {
        let name = #"x"}); db.users.createIndex({"evil": 1}, {"unique": true}); //"#
        let ddl = Self.driverDDL(collection: "users", indexes: [(name: name, key: ["k": 1], options: [])])
        let script = MQLCollectionDefinition.script(fromDDL: ddl, collection: "users")
        #expect(script == """
        // Indexes
        db.users.createIndex({"k": 1}, {"name": "x"});
        \(MQLCollectionDefinition.skippedStatementComment)
        // "})
        """)
        Self.expectAllowlistedShapes(script, collection: "users")
    }

    @Test("Statements for another collection or of any other kind are left out")
    func otherStatementsAreLeftOut() {
        let ddl = """
        // Collection: users
        db.orders.createIndex({"k": 1}, {"name": "k_1"})
        db.users.drop()
        db.users.createIndex({"k": 1}, {"name": "k_1"})
        db.runCommand({"collMod": "orders", "validator": {}})
        db.runCommand({"collMod": "users", "validator": {}, "validationLevel": "off"})
        """
        let script = MQLCollectionDefinition.script(fromDDL: ddl, collection: "users")
        #expect(script == """
        \(MQLCollectionDefinition.skippedStatementComment)
        db.users.createIndex({"k": 1}, {"name": "k_1"});
        \(MQLCollectionDefinition.skippedStatementComment)
        """)
    }

    @Test("Every spelling of this collection's accessor is read, and written back one way")
    func accessorSpellingsAreRead() {
        for accessor in ["db.users", "db[\"users\"]", "db['users']", "db.getCollection(\"users\")"] {
            let ddl = "// Collection: users\n\(accessor).createIndex({\"k\": 1})"
            #expect(MQLCollectionDefinition.script(fromDDL: ddl, collection: "users") == "db.users.createIndex({\"k\": 1});")
        }
    }

    @Test("A definition with no collection header, such as a view's, writes nothing")
    func viewDefinitionWritesNothing() {
        let ddl = "// View: recent\ndb.createView(\"recent\", \"orders\", [ ])"
        #expect(MQLCollectionDefinition.script(fromDDL: ddl, collection: "recent").isEmpty)
        #expect(MQLCollectionDefinition.script(fromDDL: "", collection: "recent").isEmpty)
    }

    @Test("A definition with nothing after its header writes nothing")
    func headerOnlyWritesNothing() {
        #expect(MQLCollectionDefinition.script(fromDDL: "// Collection: users", collection: "users").isEmpty)
    }
}
