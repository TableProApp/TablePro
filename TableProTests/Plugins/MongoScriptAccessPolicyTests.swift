//
//  MongoScriptAccessPolicyTests.swift
//  TableProTests
//

import Foundation
import Testing

struct MongoScriptAccessPolicyTests {
    private static let readOperations = [
        "currentDatabase", "useDatabase", "listCollections", "listIndexes", "countDocuments",
        "estimatedDocumentCount", "distinct", "collectionStats", "openCursor", "cursorConfigure",
        "cursorFetch", "cursorCount", "cursorExplain", "cursorClose", "newObjectId", "hexToBase64",
        "encodeUuid", "sleep"
    ]

    private static let writeOperations = [
        "insertOne", "insertMany", "update", "replace", "delete", "findAndModify", "bulkWrite",
        "createIndex", "dropIndex", "dropCollection", "renameCollection"
    ]

    private func command(_ document: String) -> [String: Any] {
        ["op": "command", "command": document]
    }

    private func allowsRead(_ op: String, _ request: [String: Any] = [:]) -> Bool {
        MongoScriptAccessPolicy.allows(op: op, request: request, access: .read)
    }

    @Test("A read may make every call the prelude's reads make")
    func readOperationsAreAllowed() {
        for op in Self.readOperations {
            #expect(allowsRead(op), "\(op)")
        }
        #expect(MongoScriptAccessPolicy.readOperations == Set(Self.readOperations))
    }

    @Test("A read may not write, nor make a call the policy does not know")
    func writeOperationsAreRefused() {
        for op in Self.writeOperations + ["mapReduce", "", "COUNTDOCUMENTS"] {
            #expect(!allowsRead(op), "\(op)")
        }
    }

    @Test("A read may send the seven commands the prelude's reads send, in any case")
    func readCommandsAreAllowed() {
        for document in [
            #"{"listCollections": 1}"#,
            #"{"dbStats": 1}"#,
            #"{"buildInfo": 1}"#,
            #"{"serverStatus": 1}"#,
            #"{"hostInfo": 1}"#,
            #"{"currentOp": 1}"#,
            #"{"listDatabases": 1}"#,
            #"{"listCollections":{"$numberInt":"1"}}"#,
            #"  {"DBSTATS": 1}"#,
            #"{"buildinfo": 1}"#,
            #"{"dbStats": 1, "drop": "users"}"#
        ] {
            #expect(allowsRead("command", command(document)), "\(document)")
        }
    }

    @Test("A read may not send any other command, explain included")
    func otherCommandsAreRefused() {
        for document in [
            #"{"drop": "users"}"#,
            #"{"dropDatabase": 1}"#,
            #"{"explain": {"find": "users"}, "verbosity": "executionStats"}"#,
            #"{"explain": {"mapReduce": "users", "out": "copy"}, "verbosity": "executionStats"}"#,
            #"{"count": "users"}"#,
            #"{"distinct": "users", "key": "a"}"#,
            #"{"collStats": "users"}"#,
            #"{"validate": "users"}"#,
            #"{"killOp": 1, "op": 7}"#,
            #"{"ping": 1}"#,
            #"{"aggregate": "users", "pipeline": [], "cursor": {}}"#,
            #"{"drop": "users", "dbStats": 1}"#
        ] {
            #expect(!allowsRead("command", command(document)), "\(document)")
        }
    }

    @Test("A command's name is its first key with escapes decoded, as libbson reads it")
    func commandNameIsTheDecodedFirstKey() {
        #expect(MongoScriptAccessPolicy.commandName(of: #"{"\u0064rop": "users"}"#) == "drop")
        #expect(!allowsRead("command", command(#"{"\u0064rop": "users"}"#)))
        #expect(allowsRead("command", command(#"{"\u0064bStats": 1}"#)))
        #expect(MongoScriptAccessPolicy.commandName(of: " \n{ \"hostInfo\" : 1 }") == "hostInfo")
        #expect(MongoScriptAccessPolicy.refusedName(op: "command", request: command(#"{"\u0064rop": "users"}"#)) == "drop")
        #expect(MongoScriptAccessPolicy.refusedName(op: "delete", request: [:]) == "delete")
    }

    @Test("A command that is missing, not text, or does not open with a readable key is refused")
    func unreadableCommandsAreRefused() {
        for document in [
            "",
            "{}",
            #"[{"dbStats": 1}]"#,
            "{dbStats: 1}",
            "{'dbStats': 1}",
            #"{"\ud800": 1}"#,
            #"{"\udc00dbStats": 1}"#,
            #"{"db\Stats": 1}"#,
            "{\"db\tStats\": 1}",
            "\u{FEFF}{\"dbStats\": 1}",
            "{\"dbStats"
        ] {
            #expect(!allowsRead("command", command(document)), "\(document)")
        }
        #expect(!allowsRead("command", [:]))
        #expect(!allowsRead("command", ["command": ["dbStats": 1]]))
    }

    @Test("Read-write access allows every call and every command")
    func readWriteAllowsEverything() {
        for op in Self.writeOperations + Self.readOperations + ["mapReduce"] {
            #expect(MongoScriptAccessPolicy.allows(op: op, request: [:], access: .readWrite), "\(op)")
        }
        #expect(MongoScriptAccessPolicy.allows(op: "command", request: command(#"{"drop": "users"}"#), access: .readWrite))
        #expect(MongoScriptAccessPolicy.allows(op: "command", request: [:], access: .readWrite))
    }

    @Test("$out and $merge write as keys at any depth, escaped or not, and in any shape")
    func writeStagesAreFound() {
        for text in [
            #"[{"$out": "copy"}]"#,
            #"[{"$match": {}}, {"$merge": {"into": "copy"}}]"#,
            #"[{"$lookup": {"from": "a", "pipeline": [{"$out": "copy"}], "as": "b"}}]"#,
            #"[{"$facet": {"x": [{"$match": {"y": [{"z": {"$merge": "c"}}]}}]}}]"#,
            #"{"pipeline": [{"$out": "copy"}]}"#,
            #"[{"\u0024out": "copy"}]"#,
            #"[{"$o\u0075t": "copy"}]"#,
            #"[{"$merg\u0065": {"into": "copy"}}]"#,
            #"{"pipeline": [], "pipeline": [{"$out": "copy"}]}"#,
            #"{"pipeline": [{"$out": "copy"}], "pipeline": []}"#,
            #"{"hint": {}, "pipeline": [{"$out": "copy"}]}"#
        ] {
            #expect(MongoScriptAccessPolicy.writesThroughPipeline(text), "\(text)")
        }
    }

    @Test("A string value spelled like a write stage is a field path, not a stage")
    func stringValuesAreNotStages() {
        for text in [
            #"[{"$group": {"_id": "$out", "n": {"$sum": {"$numberInt": "1"}}}}]"#,
            #"[{"$project": {"m": "$merge"}}]"#,
            #"[{"$match": {"f": "\u0024out"}}]"#,
            #"[{"$match": {"k": ["$out", "$merge"]}}]"#,
            #"[{"$project": {"o": "$outcome"}}]"#,
            #"[{"$project": {"m": {"$mergeObjects": [{"a": 1}, {"b": 2}]}}}]"#,
            #"[{"$match": {"$OUT": 1}}]"#,
            #"[{"$match": {"a": -1.5e+3, "b": true, "c": false, "d": null, "e": 0, "f": 2E-2}}]"#,
            "[]",
            " [ ] ",
            #"{"hint": {"a": 1}, "collation": {"locale": "fr"}, "batchSize": 10, "allowDiskUse": true, "maxTimeMS": 5}"#,
            String(repeating: "[", count: 120) + String(repeating: "]", count: 120)
        ] {
            #expect(!MongoScriptAccessPolicy.writesThroughPipeline(text), "\(text.prefix(80))")
        }
    }

    @Test("Text that is not strict JSON counts as writing")
    func unreadableTextWrites() {
        for text in [
            "",
            "   ",
            "{",
            "\"$out\"",
            "1",
            #"[{"$match": }]"#,
            "[{'$out': 'copy'}]",
            "[{$out: 'copy'}]",
            #"[{"a": NaN}]"#,
            #"[{"a": 01}]"#,
            #"[{"a": 1.}]"#,
            #"[{"a": "\x24out"}]"#,
            #"[{"\ud800": 1}]"#,
            #"[{"\udc00": 1}]"#,
            #"[] {"$out": "copy"}"#,
            "[{\"a\": \"tab\tinside\"}]",
            String(repeating: "[", count: 1_000) + String(repeating: "]", count: 1_000)
        ] {
            #expect(MongoScriptAccessPolicy.writesThroughPipeline(text), "\(text.prefix(80))")
        }
    }

    @Test("Aggregate options are checked beside the pipeline")
    func aggregateOptionsAreChecked() {
        #expect(MongoScriptAccessPolicy.writes(pipeline: "[]", options: #"{"hint": {}, "pipeline": [{"$out": "copy"}]}"#))
        #expect(MongoScriptAccessPolicy.writes(pipeline: #"[{"$out": "copy"}]"#, options: nil))
        #expect(!MongoScriptAccessPolicy.writes(pipeline: "[]", options: nil))
        #expect(!MongoScriptAccessPolicy.writes(pipeline: "[]", options: #"{"hint": {"a": 1}}"#))
    }

    @Test("A stage spliced in through a cursor's sort is in the pipeline the host checks")
    func spliceThroughSortIsSeen() throws {
        var options = MongoScriptCursorOptions.none
        try options.apply(key: "sort", value: #"{"a": 1}}, {"$out": "copy"#)
        #expect(MongoScriptAccessPolicy.writesThroughPipeline(options.decoratedPipeline(#"[{"$match": {}}]"#)))
    }
}
