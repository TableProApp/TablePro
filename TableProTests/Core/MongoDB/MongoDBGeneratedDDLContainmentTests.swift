//
//  MongoDBGeneratedDDLContainmentTests.swift
//  TableProTests
//
//  Catalog fixtures spell each name the way libbson writes it into canonical Extended JSON: the
//  quote, the backslash and the C0 controls escaped, and every other character raw, U+2028 and
//  U+2029 included.
//

import Foundation
import JavaScriptCore
import Testing

@testable import TablePro

/// Runs the DDL Show DDL and Edit View Definition write for a namespace whose name the server
/// chose, split by the editor's statement scanner and evaluated by the real prelude one statement
/// at a time, as a query tab runs it. Nothing but the statements the DDL is for may reach the host.
struct MongoDBGeneratedDDLContainmentTests {
    private typealias RecordingHost = MongoScriptPreludeTests.RecordingHost

    private static let bookkeeping: Set<String> = [
        "currentDatabase", "cursorConfigure", "cursorClose", "useDatabase", "sleep", "newObjectId"
    ]

    private static let hostileNames = [
        "v\ndb.probe.drop()",
        "v\rdb.probe.drop()",
        "v\r\ndb.probe.drop()",
        "v\u{2028}db.probe.drop()",
        "v\u{2029}db.probe.drop()",
        "v\u{85}db.probe.drop()",
        "v\u{0B}db.probe.drop()",
        "v */ db.probe.drop() /* ",
        "v\"); db.probe.drop(); (\"",
        "v'); db.probe.drop(); ('"
    ]

    /// Names that also break an escape made by hand: a backslash before a quote, which an escape
    /// of the quote alone turns into an escaped backslash and a closing quote, and the clusters an
    /// escape by `Character` misreads.
    private static let objectNames = hostileNames + [
        "v\\\"}); db.probe.drop(); //",
        "v\\\"); db.probe.drop(); //",
        "v\r\nb",
        "v\"\u{301}); db.probe.drop(); //",
        "v\\\u{301}b"
    ]

    private func libbson(_ value: String) -> String {
        var text = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": text += "\\\""
            case "\\": text += "\\\\"
            default:
                if scalar.value < 0x20 {
                    text += String(format: "\\u%04x", scalar.value)
                } else {
                    text.unicodeScalars.append(scalar)
                }
            }
        }
        return text + "\""
    }

    private func view(named name: String) throws -> MongoDBNamespaceEntry {
        try #require(MongoDBNamespaceEntry(json: """
            { "name" : \(libbson(name)), "type" : "view", "options" : { "viewOn" : "src", "pipeline" : \
            [ { "$match" : { "tag" : \(libbson(name)) } } ] }, "info" : { "readOnly" : true } }
            """))
    }

    private func collection(named name: String) throws -> MongoDBNamespaceEntry {
        try #require(MongoDBNamespaceEntry(json: """
            { "name" : \(libbson(name)), "type" : "collection", "options" : { "timeseries" : \
            { "timeField" : \(libbson(name)), "granularity" : "hours" }, "validator" : \
            { \(libbson(name)) : { "$type" : "string" } } } }
            """))
    }

    private func index(named name: String) throws -> MongoDBIndexEntry {
        try #require(MongoDBIndexEntry(json: """
            { "v" : { "$numberInt" : "2" }, "key" : { \(libbson(name)) : { "$numberInt" : "1" } }, \
            "name" : \(libbson(name)), "partialFilterExpression" : { "tag" : \(libbson(name)) } }
            """))
    }

    private func requests(runningEachStatementOf text: String, replies: [String] = []) throws -> [[String: Any]] {
        let host = RecordingHost()
        host.replies = replies
        let context = try MongoScriptContext.make(
            execute: { host.handle($0) },
            emit: { host.record(printed: $0) }
        )
        for statement in JavaScriptStatementScanner.executableStatements(in: text) {
            context.evaluateScript(statement.text)
            #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
            context.exception = nil
        }
        return host.requests.filter { !Self.bookkeeping.contains(($0["op"] as? String) ?? "") }
    }

    private func decoded(_ key: String, in json: String) -> String? {
        MongoScriptJson.member(of: json, key: key).flatMap(MongoScriptJson.decodedString)
    }

    /// Whether the only character in the text that ends a line, for JavaScript or for the editor's
    /// scanner, or that is a control character, is the line feed the layout put between lines.
    private func onlyLayoutLineFeeds(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            scalar != "\n" && (Character(scalar).isNewline || scalar.properties.generalCategory == .control)
        }
    }

    @Test("A view's DDL creates that view and runs nothing its name holds")
    func viewDDLRunsOnlyCreateView() throws {
        for name in Self.hostileNames {
            let text = MongoDBNamespaceDDL.text(name: name, entry: try view(named: name), indexes: [])
            let header = try #require(text.components(separatedBy: "\n").first)

            #expect(header.hasPrefix("// View: v"), "\(name.debugDescription)")
            #expect(onlyLayoutLineFeeds(text), "\(name.debugDescription)")

            let sent = try requests(runningEachStatementOf: text)
            #expect(sent.map { $0["op"] as? String } == ["command"], "\(name.debugDescription)")
            let command = try #require(sent.first?["command"] as? String)
            #expect(decoded("create", in: command) == name)
            #expect(decoded("viewOn", in: command) == "src")
            let pipeline = try #require(MongoScriptJson.member(of: command, key: "pipeline"))
            let stage = try #require(MongoScriptJson.topLevelElements(pipeline).first)
            let match = try #require(MongoScriptJson.member(of: stage, key: "$match"))
            #expect(decoded("tag", in: match) == name)
        }
    }

    @Test("Edit View Definition redefines that view and runs nothing its name holds")
    func collModRunsOnlyCollMod() throws {
        for name in Self.hostileNames {
            let text = try #require(try view(named: name).collModStatement())
            #expect(onlyLayoutLineFeeds(text), "\(name.debugDescription)")

            let sent = try requests(runningEachStatementOf: text)
            #expect(sent.map { $0["op"] as? String } == ["command"], "\(name.debugDescription)")
            let command = try #require(sent.first?["command"] as? String)
            #expect(decoded("collMod", in: command) == name)
        }
    }

    @Test("Drop drops the collection it names and nothing else")
    func dropRunsOnlyItsDrop() throws {
        for name in Self.objectNames {
            let text = MongoDBObjectStatements.drop(name)
            #expect(onlyLayoutLineFeeds(text) && !text.contains("\n"), "\(name.debugDescription)")

            let sent = try requests(runningEachStatementOf: text)
            #expect(sent.map { $0["op"] as? String } == ["dropCollection"], "\(name.debugDescription)")
            #expect(sent.first?["collection"] as? String == name, "\(name.debugDescription)")
        }
    }

    @Test("Truncate empties the collection it names and nothing else")
    func truncateRunsOnlyItsDelete() throws {
        for name in Self.objectNames {
            let text = MongoDBObjectStatements.truncate(name)
            #expect(onlyLayoutLineFeeds(text) && !text.contains("\n"), "\(name.debugDescription)")

            let sent = try requests(runningEachStatementOf: text, replies: [#"{"n":0}"#])
            #expect(sent.map { $0["op"] as? String } == ["delete"], "\(name.debugDescription)")
            #expect(sent.first?["collection"] as? String == name, "\(name.debugDescription)")
            #expect(sent.first?["multi"] as? Bool == true, "\(name.debugDescription)")
        }
    }

    @Test("Edit View Definition's fallback redefines the view it names and runs nothing its name holds")
    func fallbackTemplateRunsOnlyCollMod() throws {
        for name in Self.objectNames {
            let text = MongoDBObjectStatements.redefineViewTemplate(name)
            #expect(onlyLayoutLineFeeds(text) && !text.contains("\n"), "\(name.debugDescription)")

            let sent = try requests(runningEachStatementOf: text)
            #expect(sent.map { $0["op"] as? String } == ["command"], "\(name.debugDescription)")
            let command = try #require(sent.first?["command"] as? String)
            #expect(decoded("collMod", in: command) == name, "\(name.debugDescription)")
            #expect(decoded("viewOn", in: command) == "source_collection")
        }
    }

    @Test("A collection's DDL sets its validator and builds its index, and runs nothing a name or an option holds")
    func collectionDDLRunsOnlyItsStatements() throws {
        for name in Self.hostileNames {
            let text = MongoDBNamespaceDDL.text(
                name: name, entry: try collection(named: name), indexes: [try index(named: name)]
            )
            let lines = text.components(separatedBy: "\n")

            #expect(lines.first?.hasPrefix("// Collection: v") == true, "\(name.debugDescription)")
            #expect(lines.contains { $0.hasPrefix("// Time series: ") }, "\(name.debugDescription)")
            #expect(onlyLayoutLineFeeds(text), "\(name.debugDescription)")

            let sent = try requests(runningEachStatementOf: text)
            #expect(sent.map { $0["op"] as? String } == ["command", "createIndex"], "\(name.debugDescription)")
            let command = try #require(sent.first?["command"] as? String)
            #expect(decoded("collMod", in: command) == name)
            let validator = try #require(MongoScriptJson.member(of: command, key: "validator"))
            #expect(MongoScriptJson.members(of: validator).map(\.key) == [name])

            let createIndex = try #require(sent.last)
            #expect(createIndex["collection"] as? String == name)
            let keys = try #require(createIndex["keys"] as? String)
            #expect(MongoScriptJson.members(of: keys).map(\.key) == [name])
            let options = try #require(createIndex["options"] as? String)
            #expect(decoded("name", in: options) == name)
            let filter = try #require(MongoScriptJson.member(of: options, key: "partialFilterExpression"))
            #expect(decoded("tag", in: filter) == name)
        }
    }
}
