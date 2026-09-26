//
//  MongoDBFieldNameUpdateTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// Measured on MongoDB 7.0.43: a classic `$set` reads each key as a path, so `price.usd` walks into
/// a sub-document, `$price` is refused with code 52 and the empty name with code 56. Inside a
/// pipeline, `$set` of `tags.1` rewrote every element of `tags` and reported success.
struct MongoDBFieldNameUpdateTests {
    private func update(
        _ cells: [(column: String, old: PluginCellValue, new: PluginCellValue)],
        columns: [String],
        kinds: [String: BsonValueKind] = [:],
        version: String? = "7.0.43"
    ) throws -> String {
        let gen = MongoDBStatementGenerator(
            collectionName: "items",
            columns: columns,
            columnKinds: kinds,
            capabilities: { MongoDBCapabilities.parse(version) }
        )
        let change = PluginRowChange(
            rowIndex: 0,
            type: .update,
            cellChanges: cells.map { cell in
                (columnIndex: columns.firstIndex(of: cell.column) ?? 0, columnName: cell.column, oldValue: cell.old, newValue: cell.new)
            },
            originalRow: [.text("1")] + columns.dropFirst().map { _ in PluginCellValue.null }
        )
        let writes = try gen.generateRowWrites(
            from: [change], insertedRowData: [:], deletedRowIndices: [], insertedRowIndices: []
        )
        return try #require(writes.first?.statement)
    }

    /// The update argument of `updateOne(filter, update)`, parsed.
    private func updateArgument(of statement: String) throws -> Any {
        let open = try #require(statement.range(of: "}, ")).upperBound
        let text = String(statement[open ..< statement.index(before: statement.endIndex)])
        return try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private func stages(of statement: String) throws -> [[String: Any]] {
        try #require(try updateArgument(of: statement) as? [[String: Any]])
    }

    @Test("Editing a field named price.usd sends $setField with $literal, not $set on a path")
    func dottedNameUsesSetField() throws {
        let statement = try update([("price.usd", "10", "12")], columns: ["_id", "price.usd"], kinds: ["price.usd": .int32])

        let setField = #"{"field": {"$literal": "price.usd"}, "input": "$$ROOT", "value": {"$literal": 12}}"#
        #expect(statement == #"db.items.updateOne({"_id": 1}, [{"$replaceWith": {"$setField": "# + setField + "}}])")
    }

    @Test("A leading $, the empty name and __proto__ take the same route")
    func otherUnaddressableNamesUseSetField() throws {
        for name in ["$price", "", "__proto__"] {
            let statement = try update([(name, "a", "b")], columns: ["_id", name])
            let stage = try #require(try stages(of: statement).first)
            let setField = try #require((stage["$replaceWith"] as? [String: Any])?["$setField"] as? [String: Any])
            #expect((setField["field"] as? [String: Any])?["$literal"] as? String == name, "\(name)")
            #expect((setField["value"] as? [String: Any])?["$literal"] as? String == "b", "\(name)")
        }
    }

    @Test("Removing a field with a dotted name uses $unsetField")
    func dottedNameRemovalUsesUnsetField() throws {
        let statement = try update([("price.usd", "10", nil)], columns: ["_id", "price.usd"])

        #expect(statement.contains(#"{"$replaceWith": {"$unsetField": {"field": {"$literal": "price.usd"}, "input": "$$ROOT"}}}"#))
        #expect(!statement.contains(#""$unset": {"#))
    }

    @Test("A row mixing an ordinary and a dotted field is one pipeline: $set with $literal, then $replaceWith")
    func mixedRowIsOnePipeline() throws {
        let statement = try update(
            [("name", "a", "b"), ("price.usd", "10", "12"), ("note", "x", nil)],
            columns: ["_id", "name", "price.usd", "note"]
        )

        let stages = try stages(of: statement)
        #expect(stages.count == 3)
        #expect(((stages[0]["$set"] as? [String: Any])?["name"] as? [String: Any])?["$literal"] as? String == "b")
        #expect(stages[1]["$unset"] as? [String] == ["note"])
        #expect(stages[2]["$replaceWith"] != nil)
    }

    @Test("A row of ordinary fields keeps the classic $set document, which every server version reads")
    func ordinaryRowStaysClassic() throws {
        let statement = try update([("name", "a", "b"), ("note", "x", nil)], columns: ["_id", "name", "note"], version: "4.4.0")

        #expect(statement == #"db.items.updateOne({"_id": 1}, {"$set": {"name": "b"}, "$unset": {"note": ""}})"#)
    }

    @Test("A typed value inside $literal keeps its wrapper")
    func typedValueKeepsItsWrapper() throws {
        let statement = try update(
            [("when", "2024-01-02T03:04:05Z", "2024-01-02T03:04:06Z"), ("a.b", "1", "2")],
            columns: ["_id", "when", "a.b"],
            kinds: ["when": .date]
        )

        #expect(statement.contains(#""when": {"$literal": {"$date": {"$numberLong": "1704164646000"}}}"#))
    }

    @Test("A string that looks like a field path is wrapped in $literal so the pipeline does not read it")
    func pathLikeStringIsLiteral() throws {
        let statement = try update([("name", "a", "$notAPath"), ("a.b", "1", "2")], columns: ["_id", "name", "a.b"])

        #expect(statement.contains(#""name": {"$literal": "$notAPath"}"#))
    }

    @Test("A server older than 5.0 refuses before anything is sent, and an unknown version sends the pipeline")
    func pipelineNeedsMongoDB5() throws {
        #expect(throws: MongoDBWriteRefusal.fieldNeedsMongoDB5(field: "price.usd").refusal(ofRow: 0)) {
            try update([("price.usd", "10", "12")], columns: ["_id", "price.usd"], version: "4.4.29")
        }
        let unknown = try update([("price.usd", "10", "12")], columns: ["_id", "price.usd"], version: nil)
        #expect(unknown.contains("$setField"))
    }

    @Test("$setField is known from 5.0 on, and unknown when the version is")
    func fieldExpressionCapability() {
        #expect(MongoDBCapabilities.parse("4.4.29").supportsFieldExpressions == false)
        #expect(MongoDBCapabilities.parse("5.0.0").supportsFieldExpressions == true)
        #expect(MongoDBCapabilities.parse("7.0.43").supportsFieldExpressions == true)
        #expect(MongoDBCapabilities.parse(nil).supportsFieldExpressions == nil)
    }

    // MARK: - Pipeline and nested paths together

    @Test("A row that edits price.usd and tags[1] writes the whole tags array, and no stage names a path")
    func pipelineWritesArraysWhole() throws {
        let statement = try update(
            [("price.usd", "10", "12"), ("tags", #"["a","b","c"]"#, #"["a","Z","c"]"#)],
            columns: ["_id", "price.usd", "tags"],
            kinds: ["tags": .array]
        )

        let stages = try stages(of: statement)
        let set = try #require(stages.first?["$set"] as? [String: Any])
        #expect(set.keys.allSatisfy { !$0.contains(".") })
        #expect((set["tags"] as? [String: Any])?["$literal"] as? [String] == ["a", "Z", "c"])
        #expect(!statement.contains("tags.1"))
    }

    @Test("A removal inside an array of documents is written as the whole array under the pipeline route")
    func pipelineWritesNestedRemovalWhole() throws {
        let statement = try update(
            [("$p", "1", "2"), ("items", #"[{"sku":"a","qty":1}]"#, #"[{"sku":"a"}]"#)],
            columns: ["_id", "$p", "items"],
            kinds: ["items": .array]
        )

        let stages = try stages(of: statement)
        let set = try #require(stages.first?["$set"] as? [String: Any])
        let items = try #require((set["items"] as? [String: Any])?["$literal"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items[0]["qty"] == nil)
        #expect(!statement.contains("items.0"))
        #expect(stages.allSatisfy { $0["$unset"] == nil })
    }

    @Test("The same edits without a special name stay classic and name only the changed paths")
    func classicRouteKeepsPaths() throws {
        let statement = try update(
            [("tags", #"["a","b","c"]"#, #"["a","Z","c"]"#), ("items", #"[{"sku":"a","qty":1}]"#, #"[{"sku":"a"}]"#)],
            columns: ["_id", "tags", "items"],
            kinds: ["tags": .array, "items": .array]
        )

        #expect(statement == #"db.items.updateOne({"_id": 1}, {"$set": {"tags.1": "Z"}, "$unset": {"items.0.qty": ""}})"#)
    }

    // MARK: - Inserts

    @Test("A new document cannot hold __proto__ or an empty name, which the shell cannot write")
    func insertRefusesUnwritableNames() {
        for name in ["__proto__", ""] {
            let gen = MongoDBStatementGenerator(collectionName: "items", columns: ["_id", name])
            #expect(throws: MongoDBWriteRefusal.unwritableFieldName(field: name).refusal(ofRow: 0), "\(name)") {
                try gen.generateRowWrites(
                    from: [PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)],
                    insertedRowData: [0: [nil, "x"]],
                    deletedRowIndices: [],
                    insertedRowIndices: [0]
                )
            }
        }
    }

    @Test("A new document keeps a dotted or $ name as a literal key, which insert accepts")
    func insertKeepsDottedNames() throws {
        let gen = MongoDBStatementGenerator(collectionName: "items", columns: ["_id", "k.d", "$q"])

        let writes = try gen.generateRowWrites(
            from: [PluginRowChange(rowIndex: 0, type: .insert, cellChanges: [], originalRow: nil)],
            insertedRowData: [0: [nil, "7", "8"]],
            deletedRowIndices: [],
            insertedRowIndices: [0]
        )

        #expect(writes.first?.statement == #"db.items.insertOne({"k.d": 7, "$q": 8})"#)
    }
}
