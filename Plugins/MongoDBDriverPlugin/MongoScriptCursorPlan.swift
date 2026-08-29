import Foundation

/// The query a lazy cursor stands for, read off it without running it.
///
/// A streaming export wants the shape rather than the documents, so it can hand the query to the
/// driver's own cursor stream and page through a collection larger than memory.
struct MongoScriptCursorPlan: Sendable {
    let database: String
    let collection: String
    let isFind: Bool
    let filter: String
    let pipeline: String
    let options: MongoScriptCursorOptions

    var sort: String? { options.sort }
    var projection: String? { options.projection }
    var skip: Int { options.skip ?? 0 }
    var limit: Int? { options.limit }
}
