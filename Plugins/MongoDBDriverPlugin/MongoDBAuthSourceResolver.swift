import Foundation

enum MongoDBAuthSourceResolver {
    static let defaultAuthSource = "admin"

    static func resolve(explicitAuthSource: String?, configuredDatabase: String, useSrv: Bool) -> String {
        if let explicitAuthSource, !explicitAuthSource.isEmpty {
            return explicitAuthSource
        }
        guard !useSrv, !configuredDatabase.isEmpty else {
            return defaultAuthSource
        }
        return configuredDatabase
    }
}
