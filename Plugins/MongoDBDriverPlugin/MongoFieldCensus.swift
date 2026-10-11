import Foundation
import TableProPluginKit

struct MongoFieldCensus {
    struct Tally {
        let field: String
        let documents: Int64
        let example: Any
    }

    struct Request: Sendable {
        let pipeline: String
        let optionsJson: String?
    }

    private static let tallyStages = [
        "{\"$project\": {\"_id\": 0, \"pair\": {\"$objectToArray\": \"$$ROOT\"}}}",
        "{\"$unwind\": \"$pair\"}",
        "{\"$group\": {\"_id\": {\"$arrayToObject\": [[[\"$pair.k\", {\"$type\": \"$pair.v\"}]]]}, "
            + "\"name\": {\"$first\": \"$pair.k\"}, "
            + "\"documents\": {\"$sum\": 1}, \"example\": {\"$first\": \"$pair.v\"}}}"
    ]

    private static let writingStages: Set<String> = ["$out", "$merge"]

    let tallies: [Tally]

    init(tallies: [Tally]) {
        self.tallies = tallies
    }

    init(groups: [[String: Any]]) {
        self.init(tallies: groups.compactMap(Self.tally(from:)))
    }

    var fields: [String] {
        Set(tallies.map(\.field)).sorted()
    }

    func kinds(representation: MongoDBUuidRepresentation) -> [String: BsonValueKind] {
        var votes: [String: [BsonValueKind: Int64]] = [:]
        for tally in tallies where !(tally.example is NSNull) {
            let kind = BsonDocumentFlattener.valueKind(for: tally.example, representation: representation)
            votes[tally.field, default: [:]][kind, default: 0] += tally.documents
        }
        return votes.compactMapValues { fieldVotes in
            fieldVotes.max { $0.value < $1.value }?.key
        }
    }

    static func request(for plan: MongoScriptCursorPlan, limit ceiling: Int, timeoutMS: Int32) -> Request? {
        let sourceStages = plan.isFind
            ? findStages(of: plan, limit: ceiling)
            : aggregateStages(of: plan.pipeline, limit: ceiling)
        guard let sourceStages else { return nil }
        return Request(
            pipeline: "[\((sourceStages + tallyStages).joined(separator: ", "))]",
            optionsJson: plan.options.aggregateOptionsJson(timeoutMS: timeoutMS)
        )
    }

    private static func findStages(of plan: MongoScriptCursorPlan, limit ceiling: Int) -> [String] {
        var stages = ["{\"$match\": \(plan.filter)}"]
        let isPaged = plan.options.skip != nil || plan.options.limit != nil
        if isPaged, let sort = document(plan.sort) { stages.append("{\"$sort\": \(sort)}") }
        if plan.skip > 0 { stages.append("{\"$skip\": \(plan.skip)}") }
        stages += limitStage(plan.options.effectiveLimit(ceiling: ceiling))
        if let projection = document(plan.projection) { stages.append("{\"$project\": \(projection)}") }
        return stages
    }

    private static func aggregateStages(of pipeline: String, limit ceiling: Int) -> [String]? {
        guard let data = pipeline.data(using: .utf8),
              let stages = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !stages.contains(where: { !writingStages.isDisjoint(with: $0.keys) }) else {
            return nil
        }
        let trimmed = pipeline.trimmingCharacters(in: .whitespacesAndNewlines)
        let inner = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return (inner.isEmpty ? [] : [inner]) + limitStage(ceiling)
    }

    private static func limitStage(_ limit: Int) -> [String] {
        limit > 0 ? ["{\"$limit\": \(limit)}"] : []
    }

    private static func document(_ text: String?) -> String? {
        guard let text else { return nil }
        let compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty, compact != "null", compact != "{}" else { return nil }
        return text
    }

    private static func tally(from group: [String: Any]) -> Tally? {
        guard let field = group["name"] as? String,
              let documents = MongoScriptJson.numeric(group["documents"]) else {
            return nil
        }
        return Tally(field: field, documents: documents, example: group["example"] ?? NSNull())
    }
}
