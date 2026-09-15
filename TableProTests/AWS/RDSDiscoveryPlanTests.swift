import Foundation
@testable import TablePro
import Testing

@Suite("RDS discovery plan")
struct RDSDiscoveryPlanTests {
    private func instance(
        identifier: String,
        engine: String,
        cluster: String? = nil,
        address: String? = "host.abc123.us-east-1.rds.amazonaws.com",
        port: Int? = 5_432,
        iam: Bool = false
    ) -> RDSInstance {
        RDSInstance(
            identifier: identifier,
            engine: engine,
            engineVersion: nil,
            status: "available",
            endpoint: address == nil && port == nil ? nil : RDSInstanceEndpoint(address: address, port: port),
            databaseName: nil,
            adminUsername: nil,
            clusterIdentifier: cluster,
            iamAuthenticationEnabled: iam,
            isPubliclyAccessible: false
        )
    }

    private func cluster(
        identifier: String,
        engine: String = "aurora-mysql",
        endpoint: String? = "c.cluster-abc.us-east-1.rds.amazonaws.com",
        readerEndpoint: String? = "c.cluster-ro-abc.us-east-1.rds.amazonaws.com",
        port: Int? = nil
    ) -> RDSCluster {
        RDSCluster(
            identifier: identifier,
            engine: engine,
            engineVersion: nil,
            status: "available",
            endpoint: endpoint,
            readerEndpoint: readerEndpoint,
            port: port,
            databaseName: nil,
            adminUsername: nil,
            iamAuthenticationEnabled: true,
            members: [RDSClusterMember(instanceIdentifier: "c-1", isWriter: true)]
        )
    }

    @Test("A cluster becomes one writer row and one reader row, and its members drop out")
    func clusterFlattening() {
        let databases = RDSDiscoveryPlan.flatten(
            region: "us-east-1",
            instances: [
                instance(identifier: "c-1", engine: "aurora-mysql", cluster: "analytics", port: 3_306),
                instance(identifier: "standalone", engine: "postgres")
            ],
            clusters: [cluster(identifier: "analytics")]
        )

        #expect(databases.count == 3)
        #expect(databases.filter { $0.kind == .clusterWriter }.map(\.identifier) == ["analytics"])
        #expect(databases.filter { $0.kind == .clusterReader }.map(\.identifier) == ["analytics"])
        #expect(databases.filter { $0.kind == .instance }.map(\.identifier) == ["standalone"])
    }

    @Test("A cluster with no port falls back to the engine default")
    func portFallback() {
        let mysql = RDSDiscoveryPlan.flatten(
            region: "us-east-1",
            instances: [],
            clusters: [cluster(identifier: "a", engine: "aurora-mysql")]
        )
        #expect(mysql.allSatisfy { $0.port == 3_306 })

        let postgres = RDSDiscoveryPlan.flatten(
            region: "us-east-1",
            instances: [],
            clusters: [cluster(identifier: "b", engine: "aurora-postgresql")]
        )
        #expect(postgres.allSatisfy { $0.port == 5_432 })
    }

    @Test("A cluster with no endpoint is kept and marked unimportable")
    func endpointlessCluster() {
        let databases = RDSDiscoveryPlan.flatten(
            region: "us-east-1",
            instances: [],
            clusters: [cluster(identifier: "pending", endpoint: nil, readerEndpoint: nil, port: 5_432)]
        )
        #expect(databases.count == 1)
        #expect(databases[0].isImportable == false)
    }

    @Test("A reader endpoint equal to the writer endpoint produces no second row")
    func identicalReaderEndpoint() {
        let shared = "c.cluster-abc.us-east-1.rds.amazonaws.com"
        let databases = RDSDiscoveryPlan.flatten(
            region: "us-east-1",
            instances: [],
            clusters: [cluster(identifier: "a", endpoint: shared, readerEndpoint: shared)]
        )
        #expect(databases.map(\.kind) == [.clusterWriter])
    }

    @Test("An instance whose cluster was not returned is kept")
    func orphanedClusterMember() {
        let databases = RDSDiscoveryPlan.flatten(
            region: "eu-west-1",
            instances: [instance(identifier: "member", engine: "aurora-mysql", cluster: "invisible")],
            clusters: []
        )
        #expect(databases.map(\.identifier) == ["member"])
    }

    @Test("Engines map to a driver or are reported, never guessed")
    func engineMapping() {
        #expect(RDSEngineCatalog.databaseType(forEngine: "mysql") == .mysql)
        #expect(RDSEngineCatalog.databaseType(forEngine: "aurora") == .mysql)
        #expect(RDSEngineCatalog.databaseType(forEngine: "aurora-mysql") == .mysql)
        #expect(RDSEngineCatalog.databaseType(forEngine: "mariadb") == .mariadb)
        #expect(RDSEngineCatalog.databaseType(forEngine: "postgres") == .postgresql)
        #expect(RDSEngineCatalog.databaseType(forEngine: "aurora-postgresql") == .postgresql)
        #expect(RDSEngineCatalog.databaseType(forEngine: "oracle-ee") == .oracle)
        #expect(RDSEngineCatalog.databaseType(forEngine: "oracle-se2-cdb") == .oracle)
        #expect(RDSEngineCatalog.databaseType(forEngine: "custom-oracle-ee") == .oracle)
        #expect(RDSEngineCatalog.databaseType(forEngine: "sqlserver-ex") == .mssql)
        #expect(RDSEngineCatalog.databaseType(forEngine: "custom-sqlserver-se") == .mssql)
        #expect(RDSEngineCatalog.databaseType(forEngine: "SQLSERVER-EE") == .mssql)

        #expect(RDSEngineCatalog.databaseType(forEngine: "docdb") == nil)
        #expect(RDSEngineCatalog.databaseType(forEngine: "neptune") == nil)
        #expect(RDSEngineCatalog.databaseType(forEngine: "db2-se") == nil)
        #expect(RDSEngineCatalog.databaseType(forEngine: "quantum-db-9") == nil)
        #expect(RDSEngineCatalog.defaultPort(forEngine: "neptune") == nil)
        #expect(RDSEngineCatalog.defaultPort(forEngine: "oracle-ee") == 1_521)
        #expect(RDSEngineCatalog.defaultPort(forEngine: "sqlserver-web") == 1_433)
    }
}
