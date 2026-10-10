import Foundation
@testable import TablePro
import TableProImport
import Testing

struct RDSDiscoveryReconcilerTests {
    private func exportable(
        name: String = "orders",
        host: String = "orders.abc123.us-east-1.rds.amazonaws.com",
        port: Int = 5_432,
        database: String = "",
        username: String = ""
    ) -> ExportableConnection {
        ExportableConnection(
            name: name,
            host: host,
            port: port,
            database: database,
            username: username,
            type: DatabaseType.postgresql.rawValue,
            additionalFields: ["awsAuth": "sso", "awsRegion": "us-east-1"]
        )
    }

    @Test("A discovered row adopts the identity of a saved connection on the same endpoint")
    func adoptsExistingIdentity() {
        let adopted = RDSDiscoveryReconciler.adoptingExistingIdentity(
            [exportable()],
            existing: [
                RDSDiscoveryReconciler.ExistingEndpoint(
                    host: "Orders.abc123.us-east-1.RDS.amazonaws.com",
                    port: 5_432,
                    database: "orders",
                    username: "app_ro"
                )
            ]
        )

        #expect(adopted[0].username == "app_ro")
        #expect(adopted[0].database == "orders")
        #expect(adopted[0].additionalFields?["awsAuth"] == "sso")
    }

    @Test("Two saved connections on one endpoint are ambiguous, so nothing is adopted")
    func ambiguousEndpoint() {
        let endpoint = { (username: String) in
            RDSDiscoveryReconciler.ExistingEndpoint(
                host: "orders.abc123.us-east-1.rds.amazonaws.com",
                port: 5_432,
                database: "orders",
                username: username
            )
        }
        let adopted = RDSDiscoveryReconciler.adoptingExistingIdentity(
            [exportable()],
            existing: [endpoint("app_ro"), endpoint("app_rw")]
        )

        #expect(adopted[0].username.isEmpty)
        #expect(adopted[0].database.isEmpty)
    }

    @Test("A different endpoint keeps the discovered values")
    func leavesOtherEndpointsAlone() {
        let adopted = RDSDiscoveryReconciler.adoptingExistingIdentity(
            [exportable(database: "orders")],
            existing: [
                RDSDiscoveryReconciler.ExistingEndpoint(
                    host: "other.abc123.us-east-1.rds.amazonaws.com",
                    port: 5_432,
                    database: "other",
                    username: "someone"
                )
            ]
        )

        #expect(adopted[0].username.isEmpty)
        #expect(adopted[0].database == "orders")
    }

    @Test("collected wraps the rows as a cloud discovery, with reader endpoints unchecked")
    func collectedMarksReaderEndpoints() throws {
        let writer = exportable(name: "analytics", host: "analytics.cluster-abc.us-east-1.rds.amazonaws.com")
        let reader = exportable(name: "analytics (reader)", host: "analytics.cluster-ro-abc.us-east-1.rds.amazonaws.com")

        let collected = try RDSDiscoveryReconciler.collected(
            for: [writer, reader],
            deselectedHosts: [" Analytics.Cluster-RO-abc.us-east-1.rds.amazonaws.com "]
        )

        #expect(collected.source == .cloudDiscovery(name: "AWS"))
        #expect(collected.source.offersReplace == false)
        #expect(collected.bundle.connections.map { $0.settings } == [writer, reader])
        let readerRef = try #require(collected.bundle.connections.last?.ref)
        #expect(collected.unsuggestedConnections == [readerRef])
        #expect(collected.bundle.credentials.isEmpty)
        #expect(collected.bundle.savedQueries.isEmpty)
    }

    @Test("A discovered row that adopted a saved connection's identity matches it as a duplicate")
    func duplicateDetection() throws {
        let connections = RDSDiscoveryReconciler.adoptingExistingIdentity(
            [exportable()],
            existing: [
                RDSDiscoveryReconciler.ExistingEndpoint(
                    host: "orders.abc123.us-east-1.rds.amazonaws.com",
                    port: 5_432,
                    database: "orders",
                    username: "app_ro"
                )
            ]
        )
        let collected = try RDSDiscoveryReconciler.collected(for: connections, deselectedHosts: [])
        let settings = try #require(collected.bundle.connections.first?.settings)

        #expect(ConnectionMatchKey(settings) == ConnectionMatchKey(
            host: "orders.abc123.us-east-1.rds.amazonaws.com",
            port: 5_432,
            database: "orders",
            username: "app_ro",
            redisDatabase: nil
        ))
    }

    @Test("AWS error codes map to the recovery the user needs")
    func errorMapping() {
        #expect(
            RDSDiscoveryError.mapping(code: "AccessDenied", message: "", region: "us-east-1")
                == .accessDenied(region: "us-east-1")
        )
        #expect(
            RDSDiscoveryError.mapping(code: "ExpiredTokenException", message: "", region: "us-east-1")
                == .expiredCredentials(region: "us-east-1")
        )
        #expect(
            RDSDiscoveryError.mapping(code: "UnrecognizedClientException", message: "", region: "us-east-1")
                == .invalidCredentials(region: "us-east-1")
        )
        #expect(
            RDSDiscoveryError.mapping(code: "OptInRequired", message: "", region: "ap-east-1")
                == .regionNotEnabled(region: "ap-east-1")
        )
        #expect(
            RDSDiscoveryError.mapping(code: "Throttling", message: "", region: "us-east-1")
                == .throttled(region: "us-east-1")
        )
        #expect(
            RDSDiscoveryError.mapping(code: "RequestTimeTooSkewed", message: "", region: "us-east-1")
                == .clockSkew(region: "us-east-1")
        )
        #expect(
            RDSDiscoveryError.mapping(code: "SignatureDoesNotMatch", message: "", region: "us-east-1")
                == .signatureMismatch(region: "us-east-1")
        )
        #expect(
            RDSDiscoveryError.mapping(code: "SomethingNew", message: "detail", region: "us-east-1")
                == .service(region: "us-east-1", code: "SomethingNew", message: "detail")
        )
        #expect(RDSDiscoveryError.expiredCredentials(region: "us-east-1").isCredentialFailure)
        #expect(RDSDiscoveryError.accessDenied(region: "us-east-1").isCredentialFailure == false)
        #expect(RDSDiscoveryError.clockSkew(region: "us-east-1").errorDescription?.contains("clock") == true)
    }
}
