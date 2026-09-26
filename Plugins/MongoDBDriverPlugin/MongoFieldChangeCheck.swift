//
//  MongoFieldChangeCheck.swift
//  MongoDBDriverPlugin
//

import Foundation
import TableProPluginKit

/// Reads the server for a save's field renames and removals and answers for the save as a whole.
///
/// `review` reads the catalog alone and is what SQL Preview pays for, and keeps the collection's
/// `listCollections` entry as the review's basis. `refusalBeforeWriting` reads the catalog again,
/// because the prompts between the two can take any length of time, and refuses when the entry is
/// no longer the one the user confirmed a save for. Then it reads the documents, bounded by the
/// query timeout and ended on the server if the task is cancelled, and reads the catalog a last
/// time, because each of those scans can run for minutes. Every read goes to the primary, where the
/// writes go. A read the user's role does not allow stops the save rather than letting it run
/// unchecked. `shortfallAfterWriting` checks what the statements left behind.
struct MongoFieldChangeCheck {
    let connection: MongoDBConnection
    let database: String
    let collection: String

    func review(operations: [PluginSchemaOperation]) async throws -> PluginSchemaChangeReview {
        let plan = MongoFieldChangePlan(operations: operations)
        guard !plan.isEmpty else { return PluginSchemaChangeReview() }
        if let refusal = plan.refusal { return PluginSchemaChangeReview(refusal: refusal) }

        let read = try await assess(plan)
        if let refusal = read.assessment.refusal { return PluginSchemaChangeReview(refusal: refusal) }
        return PluginSchemaChangeReview(
            leadingStatements: read.assessment.leadingStatements(
                collection: collection, writeConcern: connection.configuredWriteConcern
            ),
            basis: read.infoJson
        )
    }

    func refusalBeforeWriting(
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String? {
        let plan = MongoFieldChangePlan(operations: operations)
        guard !plan.isEmpty else { return nil }
        if let refusal = plan.refusal { return refusal }

        let checked = try await assess(plan)
        if let refusal = checked.assessment.refusal
            ?? MongoFieldChangeAssessment.changedSinceComposedRefusal(
                composedFrom: review.basis, current: checked.infoJson, collection: collection
            ) {
            return refusal
        }
        if let refusal = try await documentRefusal(plan, assessment: checked.assessment, info: checked.info) {
            return refusal
        }
        return MongoFieldChangeAssessment.changedDuringChecksRefusal(
            checked: checked, current: try await assess(plan), collection: collection
        )
    }

    /// What the statements left behind, checked once all of them have run.
    ///
    /// First the documents that still hold an old name: one another client wrote it into while an
    /// `updateMany` ran, and one it gave the new name to before the rename reached it, which the
    /// rename's filter then skips. Then, when the save rewrote the validator, a document the new
    /// validator rejects: the `collMod` checks no document, so one another client gave only the new
    /// name after the last check before writing was accepted by the old validator, which did not
    /// read that name, and is left failing the rule it now falls under. `review` is what the save
    /// was composed with, and the check before writing refused unless its basis was still the
    /// collection's entry, so the validator, level and action read from it are the ones the
    /// statements ran against.
    func shortfallAfterWriting(
        operations: [PluginSchemaOperation],
        review: PluginSchemaChangeReview
    ) async throws -> String? {
        let plan = MongoFieldChangePlan(operations: operations)
        guard !plan.isEmpty, plan.refusal == nil else { return nil }
        var remaining: [(change: MongoFieldChange, documents: Int64)] = []
        for change in plan.changes {
            let found = try await count(MongoFieldDataProbe.remainderPipeline(change))
            remaining.append((change, found))
        }
        if let shortfall = MongoFieldDataProbe.shortfall(remaining) {
            return shortfall
        }
        if let violation = try await violationAfterWriting(plan, composedFrom: review.basis) {
            return violation
        }
        return try await dependencyAfterWriting(plan)
    }

    /// An index, a search index or a view another client made on either name while the statements
    /// ran, after the last read before writing, which nothing earlier could see.
    private func dependencyAfterWriting(_ plan: MongoFieldChangePlan) async throws -> String? {
        let indexes = try await afterWriting { try await connection.indexSpecsJson(database: database, collection: collection) }
        let searchIndexes = try await afterWriting {
            try await connection.searchIndexesJson(database: database, collection: collection)
        }
        let views = try await afterWriting { try await connection.viewInfosJson(database: database) }
        return MongoFieldDependent.dependent(
            of: plan.changes,
            indexes: indexes.compactMap(MongoIndexSpec.init(json:)),
            searchIndexes: searchIndexes.compactMap(MongoSearchIndex.init(json:)),
            views: views.compactMap(MongoViewDefinition.init(json:)),
            collection: collection
        )?.appearedDuringSave(collection: collection)
    }

    private func afterWriting<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw couldNotConfirm(error.localizedDescription)
        }
    }

    private func violationAfterWriting(_ plan: MongoFieldChangePlan, composedFrom basis: String?) async throws -> String? {
        let composed = MongoCollectionInfo(collection: collection, infoJson: basis)
        guard composed.enforcesValidator, let original = composed.validatorJson,
              let rewritten = MongoValidatorRewrite.rewrite(original, applying: plan.changes).rewrittenJson else {
            return nil
        }
        let pipeline = MongoFieldDataProbe.violationAfterWritingPipeline(
            plan.changes,
            originalValidatorJson: original,
            rewrittenValidatorJson: rewritten,
            onlyValidDocuments: composed.validatesOnlyValidDocuments
        )
        guard let found = try await readAfterWriting(pipeline) else { return nil }
        return MongoFieldDataProbe.violationAfterWriting(identifier: MongoFieldDataProbe.identifier(in: found) ?? "?", collection: collection)
    }

    private func documentRefusal(
        _ plan: MongoFieldChangePlan,
        assessment: MongoFieldChangeAssessment,
        info: MongoCollectionInfo
    ) async throws -> String? {
        if let rename = try await renameHoldingBothNames(plan) {
            return String(
                format: String(localized: "Some documents hold both %1$@ and %2$@. Remove one of the two from those documents first."),
                rename.from, rename.to
            )
        }
        if let refusal = try await oversizeRefusal(plan) {
            return refusal
        }
        guard info.enforcesValidator, let validator = assessment.effectiveValidatorJson else { return nil }
        if let refusal = try await validatorRefusal(
            plan, validatorJson: validator, onlyValidDocuments: info.validatesOnlyValidDocuments
        ) {
            return refusal
        }
        guard let original = info.validatorJson, let rewritten = assessment.rewrittenValidatorJson else { return nil }
        return try await rewrittenRuleRefusal(
            plan, originalValidatorJson: original, rewrittenValidatorJson: rewritten,
            onlyValidDocuments: info.validatesOnlyValidDocuments
        )
    }

    private func assess(_ plan: MongoFieldChangePlan) async throws -> MongoCatalogRead {
        let infoJson = try await read { try await connection.collectionInfoJson(database: database, collection: collection) }
        let info = MongoCollectionInfo(collection: collection, infoJson: infoJson)
        if let refusal = MongoFieldChangeAssessment.kindRefusal(info) {
            return MongoCatalogRead(
                infoJson: infoJson,
                info: info,
                assessment: MongoFieldChangeAssessment(refusal: refusal, rewrittenValidatorJson: nil, effectiveValidatorJson: nil)
            )
        }
        let indexes = try await read { try await connection.indexSpecsJson(database: database, collection: collection) }
        let searchIndexes = try await read {
            try await connection.searchIndexesJson(database: database, collection: collection)
        }
        let views = try await read { try await connection.viewInfosJson(database: database) }
        let assessment = MongoFieldChangeAssessment.assess(
            plan.changes,
            info: info,
            indexes: indexes.compactMap(MongoIndexSpec.init(json:)),
            searchIndexes: searchIndexes.compactMap(MongoSearchIndex.init(json:)),
            views: views.compactMap(MongoViewDefinition.init(json:))
        )
        return MongoCatalogRead(infoJson: infoJson, info: info, assessment: assessment)
    }

    private func renameHoldingBothNames(_ plan: MongoFieldChangePlan) async throws -> (from: String, to: String)? {
        let renames = plan.renames
        guard let pipeline = MongoFieldDataProbe.bothNamesPipeline(renames) else { return nil }
        let found = try await scan(pipeline)
        return MongoFieldDataProbe.renameHoldingBothNames(in: found, renames: renames)
    }

    /// A server before 4.4 cannot measure a document, so there the save goes ahead unmeasured, as
    /// it did before this check.
    private func oversizeRefusal(_ plan: MongoFieldChangePlan) async throws -> String? {
        guard let pipeline = MongoFieldDataProbe.oversizePipeline(plan.renames),
              let found = try await scan(pipeline, unmeasurableCodes: [MongoFieldDataProbe.unknownExpressionCode]) else {
            return nil
        }
        return String(
            format: String(localized: "Renaming would take the document with _id %@ past MongoDB's 16 MB limit. Choose shorter names, or shrink that document first."),
            MongoFieldDataProbe.identifier(in: found) ?? "?"
        )
    }

    private func validatorRefusal(
        _ plan: MongoFieldChangePlan,
        validatorJson: String,
        onlyValidDocuments: Bool
    ) async throws -> String? {
        let pipelines = MongoFieldDataProbe.validatorPipelines(
            plan.changes, validatorJson: validatorJson, onlyValidDocuments: onlyValidDocuments
        )
        for (change, pipeline) in zip(plan.changes, pipelines) {
            guard let found = try await scan(pipeline) else { continue }
            let identifier = MongoFieldDataProbe.identifier(in: found) ?? "?"
            guard let target = change.target else {
                return String(
                    format: String(localized: "The validator would reject the document with _id %1$@ once %2$@ is removed. Fix the document or the validator first."),
                    identifier, change.source
                )
            }
            return String(
                format: String(localized: "The validator would reject the document with _id %1$@ once %2$@ is renamed to %3$@. Fix the document or the validator first."),
                identifier, change.source, target
            )
        }
        return nil
    }

    private func rewrittenRuleRefusal(
        _ plan: MongoFieldChangePlan,
        originalValidatorJson: String,
        rewrittenValidatorJson: String,
        onlyValidDocuments: Bool
    ) async throws -> String? {
        let pipeline = MongoFieldDataProbe.rewrittenRulePipeline(
            plan.changes,
            originalValidatorJson: originalValidatorJson,
            rewrittenValidatorJson: rewrittenValidatorJson,
            onlyValidDocuments: onlyValidDocuments
        )
        guard let found = try await scan(pipeline) else { return nil }
        return String(
            format: String(localized: "Once this save updates the validator, it would reject the document with _id %@. Fix the document or the validator first."),
            MongoFieldDataProbe.identifier(in: found) ?? "?"
        )
    }

    private func scan(_ pipeline: String, unmeasurableCodes: Set<UInt32> = []) async throws -> String? {
        let maxTimeMS = MongoFieldDataProbe.maxTimeMS(queryTimeoutMS: connection.queryTimeoutMS)
        do {
            return try await connection.firstAggregatedDocumentJson(
                database: database, collection: collection, pipeline: pipeline, maxTimeMS: maxTimeMS
            )
        } catch let error as MongoDBError where unmeasurableCodes.contains(error.code) {
            return nil
        } catch let error as MongoDBError where MongoDBTimeoutPolicy.isTimeoutCode(error.code) {
            throw MongoDBError(
                code: 0,
                message: String(
                    format: String(localized: "Checking the documents of %1$@ took over %2$d seconds, so nothing was changed. Raise the query timeout in Settings and save again."),
                    collection, max(1, Int(maxTimeMS / 1_000))
                )
            )
        } catch {
            throw try couldNotCheck(error)
        }
    }

    /// A count read after the statements ran.
    private func count(_ pipeline: String) async throws -> Int64 {
        let found = try await readAfterWriting(pipeline)
        guard let remaining = MongoFieldDataProbe.remainderCount(in: found) else {
            throw couldNotConfirm(found ?? "")
        }
        return remaining
    }

    /// A read after the statements ran. Its failure cannot say nothing was changed, because the
    /// statements already did change it.
    private func readAfterWriting(_ pipeline: String) async throws -> String? {
        let maxTimeMS = MongoFieldDataProbe.maxTimeMS(queryTimeoutMS: connection.queryTimeoutMS)
        do {
            return try await connection.firstAggregatedDocumentJson(
                database: database, collection: collection, pipeline: pipeline, maxTimeMS: maxTimeMS
            )
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw couldNotConfirm(error.localizedDescription)
        }
    }

    private func couldNotConfirm(_ reason: String) -> MongoDBError {
        MongoDBError(
            code: 0,
            message: String(
                format: String(localized: "The save ran, but checking %1$@ afterwards failed: %2$@. Save again to make sure every document was changed."),
                collection, reason
            )
        )
    }

    private func read<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            throw try couldNotCheck(error)
        }
    }

    /// A cancelled task stays a cancellation. Anything else becomes the reason the save stopped.
    private func couldNotCheck(_ error: Error) throws -> Error {
        if error is CancellationError || Task.isCancelled { throw CancellationError() }
        return MongoDBError(
            code: 0,
            message: String(
                format: String(localized: "Couldn't check %1$@ before changing its documents: %2$@"),
                collection, error.localizedDescription
            )
        )
    }
}
