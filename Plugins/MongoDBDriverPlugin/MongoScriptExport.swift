import Foundation

/// What a streaming export found when it evaluated its statement.
///
/// The distinction exists so a statement is never evaluated twice. A cursor has not touched the
/// server yet, so the export can page through it; anything else has already run, and running it
/// again to fill the stream would repeat its write.
enum MongoScriptExport: Sendable {
    case cursor(MongoScriptCursorPlan)
    case result(MongoScriptStatementResult)
}
