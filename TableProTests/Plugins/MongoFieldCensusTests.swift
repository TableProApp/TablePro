import Foundation
import TableProPluginKit
import Testing

struct MongoFieldCensusTests {
    private func findPlan(filter: String = "{}", options: MongoScriptCursorOptions = .none) -> MongoScriptCursorPlan {
        MongoScriptCursorPlan(
            database: "shop", collection: "orders", isFind: true, filter: filter, pipeline: "[]", options: options
        )
    }

    private func aggregatePlan(_ pipeline: String, options: MongoScriptCursorOptions = .none) -> MongoScriptCursorPlan {
        MongoScriptCursorPlan(
            database: "shop", collection: "orders", isFind: false, filter: "{}", pipeline: pipeline, options: options
        )
    }

    private func stages(of request: MongoFieldCensus.Request?) throws -> [[String: Any]] {
        let pipeline = try #require(request?.pipeline)
        let data = try #require(pipeline.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func stageNames(of request: MongoFieldCensus.Request?) throws -> [String] {
        try stages(of: request).compactMap { $0.keys.first }
    }

    private let tallyStageNames = ["$project", "$unwind", "$group"]

    @Test("A find is tallied over the documents its filter matches, up to the stream's ceiling")
    func findTalliesItsFilter() throws {
        let request = MongoFieldCensus.request(
            for: findPlan(filter: "{\"status\": \"open\"}"), limit: 5_000_000, timeoutMS: 0
        )
        #expect(try stageNames(of: request) == ["$match", "$limit"] + tallyStageNames)
        let all = try stages(of: request)
        let match = try #require(all.first?["$match"] as? [String: Any])
        #expect(match["status"] as? String == "open")
        #expect(all[1]["$limit"] as? Int == 5_000_000)
    }

    @Test("A paged find keeps its sort, skip and limit so the tally covers the same documents")
    func pagedFindKeepsItsPaging() throws {
        var options = MongoScriptCursorOptions.none
        options.sort = "{\"createdAt\": -1}"
        options.skip = 20
        options.limit = 50
        let request = MongoFieldCensus.request(for: findPlan(options: options), limit: 5_000_000, timeoutMS: 0)

        #expect(try stageNames(of: request) == ["$match", "$sort", "$skip", "$limit"] + tallyStageNames)
        let all = try stages(of: request)
        #expect(all[2]["$skip"] as? Int == 20)
        #expect(all[3]["$limit"] as? Int == 50)
    }

    @Test("A sort without paging is left out, since it cannot change which fields exist")
    func unpagedSortIsDropped() throws {
        var options = MongoScriptCursorOptions.none
        options.sort = "{\"createdAt\": -1}"
        let request = MongoFieldCensus.request(for: findPlan(options: options), limit: 5_000_000, timeoutMS: 0)
        #expect(try stageNames(of: request) == ["$match", "$limit"] + tallyStageNames)
    }

    @Test("A find limit above the ceiling is held to the ceiling, as the stream's own find is")
    func findLimitIsHeldToTheCeiling() throws {
        var options = MongoScriptCursorOptions.none
        options.limit = 9_000_000
        let request = MongoFieldCensus.request(for: findPlan(options: options), limit: 5_000_000, timeoutMS: 0)
        #expect(try stageNames(of: request) == ["$match", "$limit"] + tallyStageNames)
        #expect(try stages(of: request)[1]["$limit"] as? Int == 5_000_000)
    }

    @Test("A find projection is applied before the tally, and an empty one is ignored")
    func findProjectionShapesTheTally() throws {
        var options = MongoScriptCursorOptions.none
        options.projection = "{\"name\": 1}"
        let projected = MongoFieldCensus.request(for: findPlan(options: options), limit: 5_000_000, timeoutMS: 0)
        #expect(try stageNames(of: projected) == ["$match", "$limit", "$project"] + tallyStageNames)
        let userProjection = try #require(try stages(of: projected)[2]["$project"] as? [String: Any])
        #expect(userProjection["name"] as? Int == 1)

        options.projection = "{ }"
        let empty = MongoFieldCensus.request(for: findPlan(options: options), limit: 5_000_000, timeoutMS: 0)
        #expect(try stageNames(of: empty) == ["$match", "$limit"] + tallyStageNames)
    }

    @Test("An aggregation is tallied over its own output, up to the stream's ceiling")
    func aggregateTalliesItsOutput() throws {
        let request = MongoFieldCensus.request(
            for: aggregatePlan("[{\"$match\": {}}, {\"$addFields\": {\"total\": 1}}]"),
            limit: 5_000_000, timeoutMS: 0
        )
        #expect(try stageNames(of: request) == ["$match", "$addFields", "$limit"] + tallyStageNames)
        #expect(try stages(of: request)[2]["$limit"] as? Int == 5_000_000)
    }

    @Test("An empty pipeline is tallied over the collection, up to the stream's ceiling")
    func emptyPipelineTalliesTheCollection() throws {
        let request = MongoFieldCensus.request(for: aggregatePlan("[]"), limit: 5_000_000, timeoutMS: 0)
        #expect(try stageNames(of: request) == ["$limit"] + tallyStageNames)
    }

    @Test("A pipeline that writes is never run a second time for a tally", arguments: [
        "[{\"$match\": {}}, {\"$out\": \"archive\"}]",
        "[{\"$merge\": {\"into\": \"archive\"}}]"
    ])
    func writingPipelineHasNoTally(pipeline: String) {
        #expect(MongoFieldCensus.request(for: aggregatePlan(pipeline), limit: 5_000_000, timeoutMS: 0) == nil)
    }

    @Test("The tally runs with the statement's hint, collation and time limit")
    func tallyKeepsTheStatementOptions() throws {
        var options = MongoScriptCursorOptions.none
        options.hint = "{\"status\": 1}"
        options.collation = "{\"locale\": \"fr\"}"
        let request = MongoFieldCensus.request(for: findPlan(options: options), limit: 5_000_000, timeoutMS: 3_000)
        let optionsJson = try #require(request?.optionsJson)
        let data = try #require(optionsJson.data(using: .utf8))
        let parsed = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((parsed["hint"] as? [String: Any])?["status"] as? Int == 1)
        #expect((parsed["collation"] as? [String: Any])?["locale"] as? String == "fr")
        #expect(parsed["maxTimeMS"] as? Int == 3_000)
    }

    @Test("Field names are grouped as object keys, which the server compares byte for byte under any collation")
    func fieldNamesAreGroupedAsObjectKeys() throws {
        let request = MongoFieldCensus.request(for: findPlan(), limit: 5_000_000, timeoutMS: 0)
        let group = try #require(try stages(of: request).last?["$group"] as? [String: Any])
        let key = try #require(group["_id"] as? [String: Any])
        #expect(Array(key.keys) == ["$arrayToObject"])
        let argument = try #require(key["$arrayToObject"] as? [Any])
        let pairs = try #require(argument.first as? [Any])
        let pair = try #require(pairs.first as? [Any])
        #expect(pair.first as? String == "$pair.k")
        #expect((pair.last as? [String: Any])?["$type"] as? String == "$pair.v")
        #expect((group["name"] as? [String: Any])?["$first"] as? String == "$pair.k")
    }

    @Test("Group replies become tallies, and one without a field name is skipped")
    func groupRepliesBecomeTallies() {
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        let census = MongoFieldCensus(groups: [
            ["_id": ["late": "date"], "name": "late", "documents": Int32(3), "example": seen],
            ["_id": ["big": "long"], "name": "big", "documents": Int64(4), "example": Int64(1)],
            ["_id": ["lost": "int"], "documents": Int32(1)]
        ])
        #expect(census.tallies.map(\.field) == ["late", "big"])
        #expect(census.tallies.map(\.documents) == [3, 4])
        #expect(census.tallies.first?.example as? Date == seen)
    }

    @Test("A group whose example is missing counts as null")
    func missingExampleIsNull() {
        let census = MongoFieldCensus(groups: [["_id": ["gone": "null"], "name": "gone", "documents": Int32(2)]])
        #expect(census.fields == ["gone"])
        #expect(census.kinds(representation: .unspecified).isEmpty)
    }

    @Test("Every tallied field is listed once, in name order")
    func fieldsAreListedOnceInNameOrder() {
        let census = MongoFieldCensus(tallies: [
            MongoFieldCensus.Tally(field: "zeta", documents: 1, example: "z"),
            MongoFieldCensus.Tally(field: "alpha", documents: 2, example: Int32(1)),
            MongoFieldCensus.Tally(field: "zeta", documents: 3, example: NSNull())
        ])
        #expect(census.fields == ["alpha", "zeta"])
    }
}
