import Foundation

enum MongoDBCreateDatabasePlan {
    static let firstCollectionFieldId = "mongoFirstCollection"

    static func firstCollectionName(from values: [String: String], databaseName: String) -> String {
        let requested = values[firstCollectionFieldId]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return requested.isEmpty ? databaseName : requested
    }
}
