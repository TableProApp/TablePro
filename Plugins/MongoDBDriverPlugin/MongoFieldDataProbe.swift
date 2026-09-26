//
//  MongoFieldDataProbe.swift
//  MongoDBDriverPlugin
//

import Foundation

/// The aggregations that read the documents a save is about to change, run on Save alone.
///
/// Each is a full pass over the documents that hold a changed field, which the catalog cannot
/// replace: a document holding both names of a rename is invisible to it, and so is a document the
/// validator would reject once the field moves. Both would stop the write partway, and a stopped
/// `updateMany` keeps what it already changed.
///
/// The stages are ones MongoDB 4.0 has, the oldest server libmongoc 1.28 connects to: `$addFields`
/// with `$$REMOVE` rather than the `$set` and `$unset` stages, which arrived in 4.2.
enum MongoFieldDataProbe {
    /// The ceiling for each pass when the query timeout is set to No limit. A scan the user cannot
    /// stop from the Structure tab must still end.
    static let unlimitedTimeoutCeilingMS: Int32 = 600_000

    static func maxTimeMS(queryTimeoutMS: Int32) -> Int32 {
        queryTimeoutMS > 0 ? queryTimeoutMS : unlimitedTimeoutCeilingMS
    }

    /// The options of every pass. Each is sent to the primary as well, as its read preference, and
    /// reads at `local`: the write it guards goes to the primary and changes what is there now,
    /// while a lagging secondary or a `majority` read concern from the connection string can miss a
    /// document the write then reaches.
    static func aggregateOptionsJson(maxTimeMS: Int32) -> String {
        "{\"maxTimeMS\": \(maxTimeMS), \"readConcern\": {\"level\": \"local\"}}"
    }

    /// Finds one document that holds both names of any rename, and says which rename. Such a
    /// document is skipped by the rename's filter, so it would keep the old name after the save.
    static func bothNamesPipeline(_ renames: [(from: String, to: String)]) -> String? {
        guard !renames.isEmpty else { return nil }
        let holdsBoth = renames.map { "{\(exists($0.from)), \(exists($0.to))}" }
        let flags = renames.enumerated().map { index, rename in
            "\"p\(index)\": {\"$and\": [\(present(rename.from)), \(present(rename.to))]}"
        }
        return "[{\"$match\": {\"$or\": [\(holdsBoth.joined(separator: ", "))]}}, {\"$limit\": 1}, "
            + "{\"$project\": {\"_id\": 0, \(flags.joined(separator: ", "))}}]"
    }

    /// The most bytes MongoDB stores in one document.
    static let largestDocumentBytes = 16 * 1_024 * 1_024

    /// Finds one document the renames would take past the most bytes MongoDB stores. A rename to a
    /// longer name adds the difference to every document holding the old one, and `updateMany` is
    /// not atomic, so such a document stops the write partway, after the ones before it changed,
    /// and every retry stops at it again. `$bsonSize` needs MongoDB 4.4.
    static func oversizePipeline(_ renames: [(from: String, to: String)]) -> String? {
        let growing = renames.filter { $0.to.utf8.count > $0.from.utf8.count }
        guard !growing.isEmpty else { return nil }
        let holdsOld = growing.map { "{\(exists($0.from))}" }
        let growth = growing.map { rename in
            "{\"$cond\": [\(present(rename.from)), \(rename.to.utf8.count - rename.from.utf8.count), 0]}"
        }
        let size = "{\"$add\": [{\"$bsonSize\": \"$$ROOT\"}, \(growth.joined(separator: ", "))]}"
        return "[{\"$match\": {\"$or\": [\(holdsOld.joined(separator: ", "))]}}, "
            + "{\"$match\": {\"$expr\": {\"$gt\": [\(size), \(largestDocumentBytes)]}}}, "
            + "{\"$limit\": 1}, {\"$project\": {\"_id\": 1}}]"
    }

    /// InvalidPipelineOperator: a server before 4.4, which has no `$bsonSize` to measure with.
    static let unknownExpressionCode: UInt32 = 168

    static func renameHoldingBothNames(
        in documentJson: String?,
        renames: [(from: String, to: String)]
    ) -> (from: String, to: String)? {
        guard let documentJson, let flags = MongoJsonValue.parse(documentJson) as? [String: Any] else { return nil }
        return renames.indices.first { flags["p\($0)"] as? Bool == true }.map { renames[$0] }
    }

    /// One pipeline per change, in the order the statements run, each finding a document the
    /// server would refuse at that statement.
    ///
    /// The statements run one at a time and the server validates every document each one changes,
    /// so every step is checked against the state the steps before it leave, never against the
    /// final state alone: renaming `p` to `x` and `q` to `y` under `dependencies: {x: ["y"]}` ends
    /// valid and still fails at the first statement on a document holding `p` and `q`. The earlier
    /// steps are replayed with the same guard their filters apply, the step itself is applied to
    /// the documents its filter selects, and a `moderate` validator first sets aside the documents
    /// it already rejects, because the server does not validate an update to one of those.
    static func validatorPipelines(
        _ changes: [MongoFieldChange],
        validatorJson: String,
        onlyValidDocuments: Bool
    ) -> [String] {
        changes.indices.map { step in
            var stages = changes[..<step].map(replay)
            stages.append("{\"$match\": \(changes[step].filterJson)}")
            if onlyValidDocuments {
                stages.append("{\"$match\": \(validatorJson)}")
            }
            stages.append(apply(changes[step]))
            stages.append("{\"$match\": {\"$nor\": [\(validatorJson)]}}")
            stages.append("{\"$limit\": 1}")
            stages.append("{\"$project\": {\"_id\": 1}}")
            return "[\(stages.joined(separator: ", "))]"
        }
    }

    /// Finds one document the rewritten validator rejects once the whole save has run, among every
    /// document that holds a name the save changes.
    ///
    /// The `collMod` moves a rule from the old name to the new one, and the server checks no
    /// document when it does. The step passes cover the documents each statement changes, because
    /// the server validates those, but a document that already holds only the new name is changed
    /// by no statement: `{new: 42}` under a rule that `old` is a string passes every step and is
    /// left failing the rule it now falls under, so the next update to it fails. So this pass
    /// replays every step and checks what is left. Under `moderate` the server stops checking a
    /// document that fails, so only a document the old validator accepted counts: one that failed
    /// before the save is left as it was.
    static func rewrittenRulePipeline(
        _ changes: [MongoFieldChange],
        originalValidatorJson: String,
        rewrittenValidatorJson: String,
        onlyValidDocuments: Bool
    ) -> String {
        rejectedByRewrittenValidator(
            changes,
            originalValidatorJson: originalValidatorJson,
            rewrittenValidatorJson: rewrittenValidatorJson,
            onlyValidDocuments: onlyValidDocuments,
            replaying: changes.map(replay)
        )
    }

    /// The same question once the statements have run, so nothing is replayed: one document the
    /// rewritten validator rejects among every document that holds a name the save changed. The
    /// server validated each document a statement changed, so under `strict` a document found here
    /// is one no statement touched, which another client wrote under the old validator after the
    /// last check before writing. Under `moderate` only a document the old validator accepts as it
    /// now stands counts, as before writing.
    static func violationAfterWritingPipeline(
        _ changes: [MongoFieldChange],
        originalValidatorJson: String,
        rewrittenValidatorJson: String,
        onlyValidDocuments: Bool
    ) -> String {
        rejectedByRewrittenValidator(
            changes,
            originalValidatorJson: originalValidatorJson,
            rewrittenValidatorJson: rewrittenValidatorJson,
            onlyValidDocuments: onlyValidDocuments,
            replaying: []
        )
    }

    /// Why a save whose statements all ran did not finish: a document the validator it put in place
    /// rejects. Saving again cannot fix that, so the message says what does.
    static func violationAfterWriting(identifier: String, collection: String) -> String {
        String(
            format: String(
                localized: """
                    The save did not finish: the updated validator of %1$@ rejects the document with _id %2$@, \
                    most likely written by another client while the save ran. Fix that document, then save again.
                    """
            ),
            collection, identifier
        )
    }

    private static func rejectedByRewrittenValidator(
        _ changes: [MongoFieldChange],
        originalValidatorJson: String,
        rewrittenValidatorJson: String,
        onlyValidDocuments: Bool,
        replaying replayStages: [String]
    ) -> String {
        var names: [String] = []
        for name in changes.flatMap(\.names) where !names.contains(name) {
            names.append(name)
        }
        var stages = ["{\"$match\": {\"$or\": [\(names.map { "{\(exists($0))}" }.joined(separator: ", "))]}}"]
        if onlyValidDocuments {
            stages.append("{\"$match\": \(originalValidatorJson)}")
        }
        stages.append(contentsOf: replayStages)
        stages.append("{\"$match\": {\"$nor\": [\(rewrittenValidatorJson)]}}")
        stages.append("{\"$limit\": 1}")
        stages.append("{\"$project\": {\"_id\": 1}}")
        return "[\(stages.joined(separator: ", "))]"
    }

    /// Counts the documents that still hold a change's old name, read once every statement has run.
    /// `$count` answers with no document at all when nothing matches.
    static func remainderPipeline(_ change: MongoFieldChange) -> String {
        "[{\"$match\": {\(exists(change.source))}}, {\"$count\": \"n\"}]"
    }

    /// The count `remainderPipeline` returned, or nil when the answer is not a count.
    static func remainderCount(in documentJson: String?) -> Int64? {
        guard let documentJson else { return 0 }
        guard let document = MongoJsonValue.parse(documentJson) as? [String: Any] else { return nil }
        if let wrapper = document["n"] as? [String: Any], wrapper.count == 1,
           let text = (wrapper["$numberInt"] ?? wrapper["$numberLong"]) as? String {
            return Int64(text)
        }
        return (document["n"] as? NSNumber)?.int64Value
    }

    /// The first change whose old name some documents still hold, as the reason the save did not
    /// finish. Each statement skips what it has already done, so saving again finishes it, or
    /// refuses and says why when a document now holds both names of a rename.
    static func shortfall(_ remaining: [(change: MongoFieldChange, documents: Int64)]) -> String? {
        guard let first = remaining.first(where: { $0.documents > 0 }) else { return nil }
        guard first.documents > 1 else {
            return String(
                format: String(localized: "The save did not finish: one document still holds %@, most likely written by another client while the save ran. Save again to finish."),
                first.change.source
            )
        }
        return String(
            format: String(localized: "The save did not finish: %1$lld documents still hold %2$@, most likely written by another client while the save ran. Save again to finish."),
            first.documents, first.change.source
        )
    }

    /// The `_id` of the document a pass found, as a person would type it.
    static func identifier(in documentJson: String?) -> String? {
        guard let documentJson, let idJson = MongoScriptJson.member(of: documentJson, key: "_id") else { return nil }
        let value = MongoJsonValue.parse(idJson)
        if let text = value as? String { return MongoScriptJson.jsonString(text) }
        guard let wrapper = value as? [String: Any], wrapper.count == 1, let key = wrapper.keys.first else { return idJson }
        switch key {
        case "$oid": return (wrapper[key] as? String).map { "ObjectId(\"\($0)\")" } ?? idJson
        case "$numberInt", "$numberLong", "$numberDouble": return wrapper[key] as? String ?? idJson
        default: return idJson
        }
    }

    /// Every expression in one `$addFields` reads the document as it came in, so a rename sets the
    /// new name from the old one and removes the old one in a single stage.
    private static func apply(_ change: MongoFieldChange) -> String {
        let source = MongoScriptJson.jsonString(change.source)
        guard let target = change.target else { return "{\"$addFields\": {\(source): \"$$REMOVE\"}}" }
        return "{\"$addFields\": {\(MongoScriptJson.jsonString(target)): \(path(change.source)), \(source): \"$$REMOVE\"}}"
    }

    /// The step as its filter applies it to every document: a rename moves the value only where the
    /// old name is present and the new one absent. Measured on 7.0.43: adding a field from a missing
    /// path removes it, so the untouched branch sets each name back to itself.
    private static func replay(_ change: MongoFieldChange) -> String {
        let source = change.source
        guard let target = change.target else { return apply(change) }
        let moves = "{\"$and\": [\(present(source)), {\"$eq\": [{\"$type\": \(path(target))}, \"missing\"]}]}"
        return "{\"$addFields\": {"
            + "\(MongoScriptJson.jsonString(target)): {\"$cond\": [\(moves), \(path(source)), \(path(target))]}, "
            + "\(MongoScriptJson.jsonString(source)): {\"$cond\": [\(moves), \"$$REMOVE\", \(path(source))]}"
            + "}}"
    }

    private static func path(_ field: String) -> String {
        MongoScriptJson.jsonString("$" + field)
    }

    private static func exists(_ field: String) -> String {
        "\(MongoScriptJson.jsonString(field)): {\"$exists\": true}"
    }

    private static func present(_ field: String) -> String {
        "{\"$ne\": [{\"$type\": \(path(field))}, \"missing\"]}"
    }
}
