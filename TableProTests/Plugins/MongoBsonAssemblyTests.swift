//
//  MongoBsonAssemblyTests.swift
//  TableProTests
//

import Foundation
import JavaScriptCore
import TableProPluginKit
import Testing

struct MongoBsonAssemblyTests {
    private typealias Part = MongoBsonAssembly.Part

    @Test("Text with no operator document below the root is handed to libbson unchanged")
    func textWithoutOperatorDocumentsIsWhole() {
        let texts = [
            "{\"status\":\"new\",\"total\":{\"$gt\":{\"$numberInt\":\"5\"}}}",
            "[{\"$match\":{\"a\":{\"$numberInt\":\"1\"}}},{\"$limit\":{\"$numberInt\":\"1\"}}]",
            "{\"count\":\"t\",\"query\":{\"a\":{\"$exists\":true,\"$type\":\"binData\"}}}",
            "{\"$type\":\"binData\"}",
            "{\"a\":{\"$binary\":\"AAAA\",\"$type\":\"00\"}}",
            "{\"a\":{\"$not\":{\"$regularExpression\":{\"pattern\":\"x\",\"options\":\"i\"}}}}",
            "{\"q\":\"{\\\"$type\\\":\\\"binData\\\"}\"}",
            "{\"a\":{\"k\":\"$type\"}}",
            "{}"
        ]
        for text in texts {
            #expect(MongoBsonAssembly.plan(text) == .whole(text))
        }
    }

    @Test("A $type operator becomes a document whose member libbson reads with a literal key")
    func typeOperatorBecomesADocument() {
        #expect(MongoBsonAssembly.plan("{\"sig\":{\"$type\":\"binData\"}}") == .parts([
            .document(key: "sig", parts: [.member("{\"$type\":\"binData\"}")])
        ]))
        #expect(MongoBsonAssembly.plan("{\"tags\":{\"$type\":[\"array\",\"null\"]}}") == .parts([
            .document(key: "tags", parts: [.member("{\"$type\":[\"array\",\"null\"]}")])
        ]))
    }

    @Test("A $regex or $options operator becomes a document, with a regular expression value inside kept whole")
    func regexOperatorBecomesADocument() {
        #expect(MongoBsonAssembly.plan("{\"name\":{\"$regex\":\"^a\",\"$exists\":true}}") == .parts([
            .document(key: "name", parts: [.member("{\"$regex\":\"^a\"}"), .member("{\"$exists\":true}")])
        ]))
        #expect(MongoBsonAssembly.plan("{\"name\":{\"$options\":\"i\",\"$regex\":\"^a\"}}") == .parts([
            .document(key: "name", parts: [.member("{\"$options\":\"i\"}"), .member("{\"$regex\":\"^a\"}")])
        ]))
        let regexValue = "{\"$regularExpression\":{\"pattern\":\"^a\",\"options\":\"i\"}}"
        #expect(MongoBsonAssembly.plan("{\"name\":{\"$regex\":\(regexValue)}}") == .parts([
            .document(key: "name", parts: [.member("{\"$regex\":\(regexValue)}")])
        ]))
    }

    @Test("A pipeline is keyed by position, and only the stage holding an operator document is taken apart")
    func pipelineElementsAreKeyedByPosition() {
        let plan = MongoBsonAssembly.plan(
            "[{\"$match\":{\"a\":{\"$type\":\"array\"}}},{\"$limit\":{\"$numberInt\":\"1\"}}]"
        )
        #expect(plan == .parts([
            .document(key: "0", parts: [
                .document(key: "$match", parts: [
                    .document(key: "a", parts: [.member("{\"$type\":\"array\"}")])
                ])
            ]),
            .member("{\"1\":{\"$limit\":{\"$numberInt\":\"1\"}}}")
        ]))
    }

    @Test("An array holding an operator document becomes a BSON array")
    func nestedArrayBecomesAnArray() {
        let plan = MongoBsonAssembly.plan("{\"$or\":[{\"a\":{\"$type\":\"string\"}},{\"b\":true}]}")
        #expect(plan == .parts([
            .array(key: "$or", parts: [
                .document(key: "0", parts: [.document(key: "a", parts: [.member("{\"$type\":\"string\"}")])]),
                .member("{\"1\":{\"b\":true}}")
            ])
        ]))
    }

    @Test("An escaped operator key is recognised, since libbson decodes a key before reading it")
    func escapedOperatorKeyIsRecognised() {
        #expect(MongoBsonAssembly.plan("{\"a\":{\"\\u0024type\":\"binData\"}}") == .parts([
            .document(key: "a", parts: [.member("{\"$type\":\"binData\"}")])
        ]))
        #expect(MongoBsonAssembly.holdsOperatorDocument("{\"a\":{\"$re\\u0067ex\":\"x\",\"$exists\":true}}"))
    }

    @Test("A value wrapper is never taken apart, whatever it holds")
    func wrapperIsNeverTakenApart() {
        let code = "{\"$code\":\"f\",\"$scope\":{\"a\":{\"$type\":\"binData\"}}}"
        #expect(MongoBsonAssembly.plan("{\"x\":\(code)}") == .parts([.member("{\"x\":\(code)}")]))
    }

    @Test("Malformed text is left to libbson rather than cut short")
    func malformedTextIsWhole() {
        let unclosed = "{\"a\":{\"$type\":\"binData\"}"
        #expect(MongoBsonAssembly.plan(unclosed) == .whole(unclosed))
    }

    @Test("Every other member keeps its exact text, duplicates included")
    func membersKeepTheirExactText() {
        let plan = MongoBsonAssembly.plan(
            "{\"a\":{\"$type\":\"double\"},\"n\":{\"$numberLong\":\"9007199254740993\"},\"f\":1.0,\"a\":2}"
        )
        #expect(plan == .parts([
            .document(key: "a", parts: [.member("{\"$type\":\"double\"}")]),
            .member("{\"n\":{\"$numberLong\":\"9007199254740993\"}}"),
            .member("{\"f\":1.0}"),
            .member("{\"a\":2}")
        ]))
    }

    @Test("Joining every part back gives the text that was planned, in order")
    func partsJoinBackToTheInput() throws {
        let texts = [
            "{\"name\":{\"$regex\":{\"$regularExpression\":{\"pattern\":\"^a\",\"options\":\"i\"}}},\"n\":1}",
            "[{\"$match\":{\"sig\":{\"$type\":\"binData\"},\"x\":[1,{\"y\":{\"$options\":\"i\",\"$regex\":\"z\"}}]}}]",
            "{\"create\":\"v\",\"validator\":{\"$or\":[{\"a\":{\"$type\":\"double\"}},{\"a\":null}]},\"a\":{\"$b\":1}}",
            "{\"_id\":{\"$oid\":\"507f1f77bcf86cd799439011\"},\"m\":{\"$type\":\"x\",\"k\":[]},\"m\":\"dup\"}"
        ]
        for text in texts {
            guard case .parts(let parts) = MongoBsonAssembly.plan(text) else {
                Issue.record("\(text) was not taken apart")
                continue
            }
            let isArray = text.hasPrefix("[")
            let body = try joined(parts, isArray: isArray)
            #expect((isArray ? "[\(body)]" : "{\(body)}") == text)
        }
    }

    @Test("The shell's own serialization of an operator document reaches the planner as a document")
    func shellOutputIsTakenApart() throws {
        let host = MongoScriptPreludeTests.RecordingHost()
        host.replies = ["1", "2", "{\"insertedIds\": [{\"$oid\": \"507f1f77bcf86cd799439011\"}], \"insertedCount\": 1}"]
        let context = try MongoScriptContext.make(
            execute: { host.handle($0) },
            emit: { host.record(printed: $0) }
        )

        context.evaluateScript("db.t.find({sig: {$type: \"binData\"}}); db.t.find({name: {$regex: /^a/i}})")
        context.evaluateScript("db.t.insertOne({m: {$regex: \"a\", $options: \"i\"}})")
        #expect(context.exception == nil)

        let filters = host.requests(op: "openCursor").compactMap { $0["filter"] as? String }
        let documents = host.requests(op: "insertOne").compactMap { $0["document"] as? String }
        #expect(filters.count == 2)
        #expect(documents.count == 1)
        for text in filters + documents {
            #expect(MongoBsonAssembly.plan(text) != .whole(text))
        }
    }

    @Test("A raw filter row and a grid regex reach the count as the same document the rows query sends")
    func filterBarOutputIsTakenApart() throws {
        let raw = try #require(MongoDBRawFilterNormalizer().normalize("{sig: {$type: \"binData\"}}"))
        #expect(MongoBsonAssembly.plan(raw) != .whole(raw))

        let builder = MongoDBQueryBuilder()
        let contains = builder.buildFilterDocument(from: [
            PluginQueryFilter(column: "name", op: "CONTAINS", value: "a", isCaseSensitive: false)
        ])
        let notContains = builder.buildFilterDocument(from: [
            PluginQueryFilter(column: "name", op: "NOT CONTAINS", value: "a", isCaseSensitive: false)
        ])
        #expect(MongoBsonAssembly.plan(contains) != .whole(contains))
        #expect(MongoBsonAssembly.plan(notContains) == .whole(notContains))
    }

    private func joined(_ parts: [Part], isArray: Bool) throws -> String {
        try parts.enumerated().map { index, part in
            let (key, value) = try keyAndValue(of: part)
            guard isArray else { return "\(MongoScriptJson.jsonString(key)):\(value)" }
            #expect(key == String(index))
            return value
        }.joined(separator: ",")
    }

    private func keyAndValue(of part: Part) throws -> (key: String, value: String) {
        switch part {
        case .member(let json):
            let members = MongoScriptJson.members(of: json)
            #expect(members.count == 1)
            let only = try #require(members.first)
            return (only.key, only.value)
        case .document(let key, let parts):
            return (key, "{\(try joined(parts, isArray: false))}")
        case .array(let key, let parts):
            return (key, "[\(try joined(parts, isArray: true))]")
        }
    }
}
