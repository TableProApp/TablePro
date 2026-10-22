import Foundation

nonisolated enum MongoDBAuthSourceResolver {
    static let defaultAuthSource = "admin"
    static let externalAuthSource = "$external"

    private static let externalMechanisms: Set<String> = ["MONGODB-X509", "MONGODB-AWS"]

    static func resolve(
        explicitAuthSource: String?,
        configuredDatabase: String,
        useSrv: Bool,
        authMechanism: String?
    ) -> String {
        if let explicitAuthSource, !explicitAuthSource.isEmpty {
            return explicitAuthSource
        }
        if let authMechanism, externalMechanisms.contains(authMechanism.uppercased()) {
            return externalAuthSource
        }
        guard !useSrv, !configuredDatabase.isEmpty else {
            return defaultAuthSource
        }
        return configuredDatabase
    }
}
