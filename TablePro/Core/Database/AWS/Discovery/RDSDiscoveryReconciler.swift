import Foundation
import TableProImport

enum RDSDiscoveryReconciler {
    static let sourceName = "AWS"

    struct ExistingEndpoint: Sendable, Equatable {
        let host: String
        let port: Int
        let database: String
        let username: String

        init(host: String, port: Int, database: String, username: String) {
            self.host = host
            self.port = port
            self.database = database
            self.username = username
        }
    }

    static func adoptingExistingIdentity(
        _ connections: [ExportableConnection],
        existing: [ExistingEndpoint]
    ) -> [ExportableConnection] {
        guard !existing.isEmpty else { return connections }
        var byEndpoint: [String: ExistingEndpoint] = [:]
        var ambiguous: Set<String> = []
        for endpoint in existing {
            let key = endpointKey(host: endpoint.host, port: endpoint.port)
            if byEndpoint.updateValue(endpoint, forKey: key) != nil {
                ambiguous.insert(key)
            }
        }

        return connections.map { connection in
            let key = endpointKey(host: connection.host, port: connection.port)
            guard !ambiguous.contains(key), let match = byEndpoint[key] else {
                return connection
            }
            var identified = connection
            identified.username = match.username
            if identified.database.isEmpty {
                identified.database = match.database
            }
            return identified
        }
    }

    static func collected(
        for connections: [ExportableConnection],
        deselectedHosts: Set<String>
    ) throws -> CollectedImport {
        let deselected = Set(deselectedHosts.map(normalizedHost))
        var builder = ConnectionBundleBuilder(appVersion: "\(sourceName) Import")
        var unsuggested: Set<BundleRef> = []
        for (index, connection) in connections.enumerated() {
            let ref = BundleRef("rds-\(index + 1)")
            builder.addConnection(connection, ref: ref)
            if deselected.contains(normalizedHost(connection.host)) {
                unsuggested.insert(ref)
            }
        }
        return CollectedImport(
            bundle: try builder.build(),
            source: .cloudDiscovery(name: sourceName),
            unsuggestedConnections: unsuggested
        )
    }

    private static func endpointKey(host: String, port: Int) -> String {
        "\(normalizedHost(host))|\(port)"
    }

    private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
