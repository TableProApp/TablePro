//
//  MongoFieldDataProbeTests.swift
//  TableProTests
//

import Foundation
import Testing

/// The pipelines here were run against MongoDB 7.0.43 in the pull request's live checks; these tests
/// pin their text and their shape so a refactor cannot quietly change what the server is asked.
struct MongoFieldDataProbeTests {
    private func stages(_ pipeline: String) throws -> [[String: Any]] {
        try #require(MongoJsonValue.parse(pipeline) as? [[String: Any]])
    }

    @Test("The both-names pass matches documents holding both names of one rename, never one of each")
    func bothNamesMatchesPairs() throws {
        let pipeline = try #require(MongoFieldDataProbe.bothNamesPipeline([("a", "b"), ("c", "d")]))
        #expect(pipeline == #"[{"$match": {"$or": [{"a": {"$exists": true}, "b": {"$exists": true}}, {"c": {"$exists": true}, "#
            + #""d": {"$exists": true}}]}}, {"$limit": 1}, {"$project": {"_id": 0, "#
            + #""p0": {"$and": [{"$ne": [{"$type": "$a"}, "missing"]}, {"$ne": [{"$type": "$b"}, "missing"]}]}, "#
            + #""p1": {"$and": [{"$ne": [{"$type": "$c"}, "missing"]}, {"$ne": [{"$type": "$d"}, "missing"]}]}}}]"#)
        let match = try #require(try stages(pipeline).first?["$match"] as? [String: Any])
        let alternatives = try #require(match["$or"] as? [[String: Any]])
        #expect(alternatives.map { Set($0.keys) } == [["a", "b"], ["c", "d"]])
        #expect(MongoFieldDataProbe.bothNamesPipeline([]) == nil)
    }

    @Test("The size pass adds each longer name's growth to documents holding the old name, and skips when nothing grows")
    func oversizePassCountsGrowth() throws {
        let pipeline = try #require(MongoFieldDataProbe.oversizePipeline([("a", "abc"), ("long", "l"), ("x", "xyz9")]))
        #expect(pipeline == #"[{"$match": {"$or": [{"a": {"$exists": true}}, {"x": {"$exists": true}}]}}, "#
            + #"{"$match": {"$expr": {"$gt": [{"$add": [{"$bsonSize": "$$ROOT"}, "#
            + #"{"$cond": [{"$ne": [{"$type": "$a"}, "missing"]}, 2, 0]}, "#
            + #"{"$cond": [{"$ne": [{"$type": "$x"}, "missing"]}, 3, 0]}]}, 16777216]}}}, "#
            + #"{"$limit": 1}, {"$project": {"_id": 1}}]"#)
        #expect(try stages(pipeline).count == 4)
        #expect(MongoFieldDataProbe.oversizePipeline([("long", "l"), ("same", "SAME")]) == nil)
        #expect(MongoFieldDataProbe.oversizePipeline([("é", "ee")]) == nil)
    }

    @Test("The pass says which rename a document holds both names of")
    func namesThePair() throws {
        let renames = [(from: "a", to: "b"), (from: "c", to: "d")]
        let found = try #require(MongoFieldDataProbe.renameHoldingBothNames(in: #"{ "p0" : false, "p1" : true }"#, renames: renames))
        #expect(found.from == "c")
        #expect(found.to == "d")
        #expect(MongoFieldDataProbe.renameHoldingBothNames(in: nil, renames: renames) == nil)
    }

    @Test("One validator pass per change, each checking the documents its statement changes")
    func oneStepPipeline() throws {
        let pipelines = MongoFieldDataProbe.validatorPipelines(
            [.rename(from: "p", to: "x")], validatorJson: #"{"$jsonSchema": {"required": ["y"]}}"#, onlyValidDocuments: false
        )
        #expect(pipelines == [#"[{"$match": {"p": {"$exists": true}, "x": {"$exists": false}}}, "#
            + #"{"$addFields": {"x": "$p", "p": "$$REMOVE"}}, {"$match": {"$nor": [{"$jsonSchema": {"required": ["y"]}}]}}, "#
            + #"{"$limit": 1}, {"$project": {"_id": 1}}]"#])
    }

    @Test("A later step replays the earlier ones with their guard, and a removal replays as a removed field")
    func laterStepsReplayEarlierOnes() throws {
        let pipelines = MongoFieldDataProbe.validatorPipelines(
            [.remove("r"), .rename(from: "p", to: "x"), .rename(from: "q", to: "y")],
            validatorJson: "{}",
            onlyValidDocuments: false
        )
        #expect(pipelines.count == 3)
        let third = try stages(pipelines[2])
        let removal = try #require(third[0]["$addFields"] as? [String: Any])
        #expect(removal.count == 1)
        #expect(removal["r"] as? String == "$$REMOVE")
        let replay = try #require(third[1]["$addFields"] as? [String: Any])
        #expect(Set(replay.keys) == ["x", "p"])
        #expect(pipelines[2].contains(#""x": {"$cond": [{"$and": [{"$ne": [{"$type": "$p"}, "missing"]}, {"$eq": [{"$type": "$x"}, "#
            + #""missing"]}]}, "$p", "$x"]}"#))
        #expect(pipelines[2].contains(#""p": {"$cond": [{"$and": [{"$ne": [{"$type": "$p"}, "missing"]}, {"$eq": [{"$type": "$x"}, "#
            + #""missing"]}]}, "$$REMOVE", "$p"]}"#))
        let match = try #require(third[2]["$match"] as? [String: Any])
        #expect(Set(match.keys) == ["q", "y"])
    }

    @Test("A moderate validator sets aside documents it already rejects before the step")
    func moderateSetsAsideInvalidDocuments() throws {
        let validator = #"{"$jsonSchema": {"required": ["k"]}}"#
        let strict = try stages(MongoFieldDataProbe.validatorPipelines([.remove("p")], validatorJson: validator, onlyValidDocuments: false)[0])
        let moderate = try stages(MongoFieldDataProbe.validatorPipelines([.remove("p")], validatorJson: validator, onlyValidDocuments: true)[0])
        #expect(strict.count == 5)
        #expect(moderate.count == 6)
        let preFilter = try #require(moderate[1]["$match"] as? [String: Any])
        #expect(preFilter["$jsonSchema"] != nil)
    }

    /// The reviewer's case, measured on 7.0.43. Validator `{old: string}`, documents `{_id: 1, old:
    /// "x"}` and `{_id: 2, new: 42}`, rename `old` to `new`. The step pass checks only `_id 1`, the
    /// one document the rename changes, so the committed code ran the `collMod` and the rename and
    /// reported success, and the next `updateOne` on `_id 2` failed with 121. This pass, run against
    /// the same collection, returned `_id 2` and the save was refused with nothing changed.
    @Test("The rewritten-rule pass checks documents holding only the new name against the rewritten validator")
    func rewrittenRuleReachesTargetOnlyDocuments() throws {
        let original = #"{"$jsonSchema": {"properties": {"old": {"bsonType": "string"}}}}"#
        let rewritten = #"{"$jsonSchema": {"properties": {"new": {"bsonType": "string"}}}}"#
        let pipeline = MongoFieldDataProbe.rewrittenRulePipeline(
            [.rename(from: "old", to: "new")],
            originalValidatorJson: original,
            rewrittenValidatorJson: rewritten,
            onlyValidDocuments: false
        )
        #expect(pipeline == #"[{"$match": {"$or": [{"old": {"$exists": true}}, {"new": {"$exists": true}}]}}, "#
            + #"{"$addFields": {"new": {"$cond": [{"$and": [{"$ne": [{"$type": "$old"}, "missing"]}, "#
            + #"{"$eq": [{"$type": "$new"}, "missing"]}]}, "$old", "$new"]}, "#
            + #""old": {"$cond": [{"$and": [{"$ne": [{"$type": "$old"}, "missing"]}, "#
            + #"{"$eq": [{"$type": "$new"}, "missing"]}]}, "$$REMOVE", "$old"]}}}, "#
            + #"{"$match": {"$nor": [{"$jsonSchema": {"properties": {"new": {"bsonType": "string"}}}}]}}, "#
            + #"{"$limit": 1}, {"$project": {"_id": 1}}]"#)

        let stepPass = try stages(
            MongoFieldDataProbe.validatorPipelines([.rename(from: "old", to: "new")], validatorJson: rewritten, onlyValidDocuments: false)[0]
        )
        let stepFilter = try #require(stepPass[0]["$match"] as? [String: Any])
        #expect(stepFilter["new"] as? [String: Bool] == ["$exists": false])
    }

    /// Under `moderate` the server stops checking a document that fails, so the question is whether
    /// the save takes a document the old validator accepted and leaves it failing the new one.
    /// Measured on 7.0.43: `{new: 42}` accepted before is refused, and `{new: 42, k: "bad"}`, which
    /// the old validator already rejected, is set aside and the save applies.
    @Test("Under moderate the rewritten-rule pass counts only documents the old validator accepted")
    func rewrittenRuleUnderModerate() throws {
        let original = #"{"$jsonSchema": {"properties": {"old": {"bsonType": "string"}}}}"#
        let rewritten = #"{"$jsonSchema": {"properties": {"new": {"bsonType": "string"}}}}"#
        let moderate = try stages(MongoFieldDataProbe.rewrittenRulePipeline(
            [.rename(from: "old", to: "new")],
            originalValidatorJson: original,
            rewrittenValidatorJson: rewritten,
            onlyValidDocuments: true
        ))
        let accepted = try #require(moderate[1]["$match"] as? [String: Any])
        let schema = try #require(accepted["$jsonSchema"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["old"])
        #expect(moderate[2]["$addFields"] != nil)
    }

    @Test("The rewritten-rule pass covers every name the save changes once, and replays every step in order")
    func rewrittenRuleCoversEveryName() throws {
        let changes: [MongoFieldChange] = [.remove("r"), .rename(from: "p", to: "x"), .rename(from: "q", to: "y")]
        let pipeline = try stages(MongoFieldDataProbe.rewrittenRulePipeline(
            changes, originalValidatorJson: "{}", rewrittenValidatorJson: #"{"a": 1}"#, onlyValidDocuments: false
        ))
        let names = try #require((pipeline[0]["$match"] as? [String: Any])?["$or"] as? [[String: Any]])
        #expect(names.flatMap(\.keys) == ["r", "p", "x", "q", "y"])
        #expect(pipeline.count == 7)
        let removal = try #require(pipeline[1]["$addFields"] as? [String: Any])
        #expect(removal["r"] as? String == "$$REMOVE")
        #expect(Set(try #require(pipeline[2]["$addFields"] as? [String: Any]).keys) == ["x", "p"])
        #expect(Set(try #require(pipeline[3]["$addFields"] as? [String: Any]).keys) == ["y", "q"])
        let rejected = try #require(pipeline[4]["$match"] as? [String: Any])
        #expect(rejected["$nor"] != nil)
    }

    /// The target-only race: a document another client gives only the new name after the last check
    /// before writing is accepted by the old validator, which does not read that name, and the
    /// `collMod` checks no document. Every statement then succeeds and skips it.
    @Test("The pass after writing checks every document holding a changed name against the rewritten validator, replaying nothing")
    func violationAfterWriting() throws {
        let original = #"{"$jsonSchema": {"properties": {"old": {"bsonType": "string"}}}}"#
        let rewritten = #"{"$jsonSchema": {"properties": {"new": {"bsonType": "string"}}}}"#
        let pipeline = MongoFieldDataProbe.violationAfterWritingPipeline(
            [.rename(from: "old", to: "new")],
            originalValidatorJson: original,
            rewrittenValidatorJson: rewritten,
            onlyValidDocuments: false
        )
        #expect(pipeline == #"[{"$match": {"$or": [{"old": {"$exists": true}}, {"new": {"$exists": true}}]}}, "#
            + #"{"$match": {"$nor": [{"$jsonSchema": {"properties": {"new": {"bsonType": "string"}}}}]}}, "#
            + #"{"$limit": 1}, {"$project": {"_id": 1}}]"#)
        let moderate = try stages(MongoFieldDataProbe.violationAfterWritingPipeline(
            [.rename(from: "old", to: "new")],
            originalValidatorJson: original,
            rewrittenValidatorJson: rewritten,
            onlyValidDocuments: true
        ))
        #expect(moderate.count == 5)
        let accepted = try #require(moderate[1]["$match"] as? [String: Any])
        #expect(accepted["$jsonSchema"] != nil)
        #expect(!moderate.contains { $0["$addFields"] != nil })

        let message = MongoFieldDataProbe.violationAfterWriting(identifier: "7", collection: "people")
        #expect(message.hasPrefix("The save did not finish: the updated validator of people rejects the document with _id 7, "))
        #expect(message.hasSuffix(" Fix that document, then save again."))
    }

    @Test("Every stage of every pass is one MongoDB 4.0 has, so none is $set or $unset")
    func stagesExistOnMongoDB40() throws {
        let stagesOn40: Set<String> = ["$match", "$addFields", "$limit", "$project"]
        let changes: [MongoFieldChange] = [.remove("r"), .rename(from: "p", to: "x"), .rename(from: "q", to: "y")]
        let validator = #"{"$jsonSchema": {"required": ["y"]}}"#
        let bothNames = try #require(MongoFieldDataProbe.bothNamesPipeline([("p", "x"), ("q", "y")]))
        let rewrittenRule = [true, false].map { onlyValid in
            MongoFieldDataProbe.rewrittenRulePipeline(
                changes, originalValidatorJson: validator, rewrittenValidatorJson: validator, onlyValidDocuments: onlyValid
            )
        }
        let pipelines = MongoFieldDataProbe.validatorPipelines(changes, validatorJson: validator, onlyValidDocuments: true)
            + MongoFieldDataProbe.validatorPipelines(changes, validatorJson: validator, onlyValidDocuments: false)
            + [bothNames] + rewrittenRule
            + [MongoFieldDataProbe.violationAfterWritingPipeline(
                changes, originalValidatorJson: validator, rewrittenValidatorJson: validator, onlyValidDocuments: true
            )]
        for pipeline in pipelines {
            for stage in try stages(pipeline) {
                #expect(stage.count == 1)
                #expect(Set(stage.keys).isSubset(of: stagesOn40), "\(stage.keys) in \(pipeline)")
            }
        }
    }

    @Test("Each pass reads at local, whatever read concern the connection string sets, within its time bound")
    func passOptions() throws {
        let options = try #require(MongoJsonValue.parse(MongoFieldDataProbe.aggregateOptionsJson(maxTimeMS: 5_000)) as? [String: Any])
        #expect(Set(options.keys) == ["maxTimeMS", "readConcern"])
        #expect(options["maxTimeMS"] as? Int == 5_000)
        #expect(options["readConcern"] as? [String: String] == ["level": "local"])
    }

    @Test("Each pass is bounded, by the query timeout or by a ceiling when there is none")
    func timeBound() {
        #expect(MongoFieldDataProbe.maxTimeMS(queryTimeoutMS: 60_000) == 60_000)
        #expect(MongoFieldDataProbe.maxTimeMS(queryTimeoutMS: 0) == MongoFieldDataProbe.unlimitedTimeoutCeilingMS)
        #expect(MongoFieldDataProbe.unlimitedTimeoutCeilingMS > 0)
    }

    @Test("The count after writing matches every document still holding the old name, for a rename and a removal")
    func remainderPipelines() throws {
        #expect(MongoFieldDataProbe.remainderPipeline(.rename(from: "old", to: "new"))
            == #"[{"$match": {"old": {"$exists": true}}}, {"$count": "n"}]"#)
        #expect(MongoFieldDataProbe.remainderPipeline(.remove("tmp"))
            == #"[{"$match": {"tmp": {"$exists": true}}}, {"$count": "n"}]"#)
        let stageNames = try stages(MongoFieldDataProbe.remainderPipeline(.remove("tmp"))).flatMap(\.keys)
        #expect(stageNames == ["$match", "$count"])
    }

    @Test("No document back from $count is zero, and an answer that is not a count is unknown")
    func remainderCounts() {
        #expect(MongoFieldDataProbe.remainderCount(in: nil) == 0)
        #expect(MongoFieldDataProbe.remainderCount(in: #"{ "n" : { "$numberInt" : "3" } }"#) == 3)
        #expect(MongoFieldDataProbe.remainderCount(in: #"{ "n" : { "$numberLong" : "5000000000" } }"#) == 5_000_000_000)
        #expect(MongoFieldDataProbe.remainderCount(in: #"{ "n" : 7 }"#) == 7)
        #expect(MongoFieldDataProbe.remainderCount(in: #"{ "x" : 1 }"#) == nil)
        #expect(MongoFieldDataProbe.remainderCount(in: "not json") == nil)
    }

    /// Measured on 7.0.43 with a second connection inserting `{old: 1, new: 2}` between the check
    /// before writing and the rename: every statement succeeded, the rename skipped that document,
    /// and this count read 1.
    @Test("A save that left the old name in some documents is not finished, and says how many hold it")
    func shortfalls() {
        let rename = MongoFieldChange.rename(from: "old", to: "new")
        let removal = MongoFieldChange.remove("tmp")
        #expect(MongoFieldDataProbe.shortfall([]) == nil)
        #expect(MongoFieldDataProbe.shortfall([(rename, 0), (removal, 0)]) == nil)
        #expect(MongoFieldDataProbe.shortfall([(rename, 1), (removal, 0)]) == String(
            format: String(localized: "The save did not finish: one document still holds %@, most likely written by another client while the save ran. Save again to finish."),
            "old"
        ))
        #expect(MongoFieldDataProbe.shortfall([(rename, 0), (removal, 12)]) == String(
            format: String(localized: "The save did not finish: %1$lld documents still hold %2$@, most likely written by another client while the save ran. Save again to finish."),
            Int64(12), "tmp"
        ))
        #expect(MongoFieldDataProbe.shortfall([(rename, 2), (removal, 12)])?.contains("old") == true)
    }

    @Test("A found document's _id is written the way a person types it")
    func identifiers() {
        #expect(MongoFieldDataProbe.identifier(in: #"{ "_id" : { "$oid" : "6ab746850efe77e864860657" } }"#)
            == #"ObjectId("6ab746850efe77e864860657")"#)
        #expect(MongoFieldDataProbe.identifier(in: #"{ "_id" : { "$numberInt" : "2" } }"#) == "2")
        #expect(MongoFieldDataProbe.identifier(in: #"{ "_id" : "abc" }"#) == #""abc""#)
        #expect(MongoFieldDataProbe.identifier(in: nil) == nil)
    }
}
