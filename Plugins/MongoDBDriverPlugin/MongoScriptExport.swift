import Foundation

/// What a streaming export found when it evaluated its statement.
///
/// The distinction exists so a statement is never evaluated twice. A cursor has not touched the
/// server yet, so the export can page through it; anything else has already run, and running it
/// again to fill the stream would repeat its write.
///
/// The statement behind a cursor can still have run writes, or a `use`, before it built one, and the
/// stream can fail after the evaluation has returned. So a cursor carries what the statement did,
/// and a failed stream reports it the way a failed statement does.
enum MongoScriptExport: Sendable {
    case cursor(MongoScriptCursorPlan, databaseSwitch: String?, writes: MongoWriteLedger)
    case result(MongoScriptStatementResult)
}
