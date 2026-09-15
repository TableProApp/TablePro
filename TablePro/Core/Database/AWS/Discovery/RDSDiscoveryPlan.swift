import Foundation

enum RDSDiscoveryPlan {
    static func flatten(
        region: String,
        instances: [RDSInstance],
        clusters: [RDSCluster]
    ) -> [DiscoveredDatabase] {
        let clusterIdentifiers = Set(clusters.map { $0.identifier.lowercased() })
        var databases: [DiscoveredDatabase] = []

        for cluster in clusters {
            let port = cluster.port ?? RDSEngineCatalog.defaultPort(forEngine: cluster.engine)
            databases.append(
                DiscoveredDatabase(
                    region: region,
                    identifier: cluster.identifier,
                    kind: .clusterWriter,
                    engine: cluster.engine,
                    engineVersion: cluster.engineVersion,
                    status: cluster.status,
                    host: cluster.endpoint,
                    port: port,
                    databaseName: cluster.databaseName,
                    adminUsername: cluster.adminUsername,
                    iamAuthenticationEnabled: cluster.iamAuthenticationEnabled,
                    isPubliclyAccessible: false
                )
            )
            if let readerEndpoint = cluster.readerEndpoint,
               !readerEndpoint.isEmpty,
               readerEndpoint.caseInsensitiveCompare(cluster.endpoint ?? "") != .orderedSame {
                databases.append(
                    DiscoveredDatabase(
                        region: region,
                        identifier: cluster.identifier,
                        kind: .clusterReader,
                        engine: cluster.engine,
                        engineVersion: cluster.engineVersion,
                        status: cluster.status,
                        host: readerEndpoint,
                        port: port,
                        databaseName: cluster.databaseName,
                        adminUsername: cluster.adminUsername,
                        iamAuthenticationEnabled: cluster.iamAuthenticationEnabled,
                        isPubliclyAccessible: false
                    )
                )
            }
        }

        for instance in instances {
            if let clusterIdentifier = instance.clusterIdentifier,
               clusterIdentifiers.contains(clusterIdentifier.lowercased()) {
                continue
            }
            databases.append(
                DiscoveredDatabase(
                    region: region,
                    identifier: instance.identifier,
                    kind: .instance,
                    engine: instance.engine,
                    engineVersion: instance.engineVersion,
                    status: instance.status,
                    host: instance.endpoint?.address,
                    port: instance.endpoint?.port ?? RDSEngineCatalog.defaultPort(forEngine: instance.engine),
                    databaseName: instance.databaseName,
                    adminUsername: instance.adminUsername,
                    iamAuthenticationEnabled: instance.iamAuthenticationEnabled,
                    isPubliclyAccessible: instance.isPubliclyAccessible
                )
            )
        }

        return databases
    }
}
