import Foundation
import TableProDatabase
import TableProModels

nonisolated struct KeyContentsPage: Sendable {
    let result: QueryResult
    let totalCount: Int?
}

nonisolated protocol KeyContentsBrowsing: DatabaseDriver {
    func keyContentsPage(ofKey key: String, limit: Int, offset: Int) async throws -> KeyContentsPage
}
