import Foundation

nonisolated enum RedisDatabaseIndex {
    static let fieldName = "redisDatabase"

    static func resolve(additionalFields: [String: String], database: String) -> Int {
        if let field = additionalFields[fieldName], let index = Int(field) { return index }
        return Int(database) ?? 0
    }
}
