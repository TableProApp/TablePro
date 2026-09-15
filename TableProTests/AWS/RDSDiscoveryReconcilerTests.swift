import Foundation
@testable import TablePro
import TableProImport
import Testing

@Suite("RDS discovery reconciliation")
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
            sshConfig: nil,
            sslConfig: nil,
            color: nil,
            tagName: nil,
            groupName: nil,
            sshProfileId: nil,
            safeModeLevel: nil,
            aiPolicy: nil,
            additionalFields: ["awsAuth": "sso", "awsRegion": "us-east-1"],
            redisDatabase: nil,
            startupCommands: nil,
            localOnly: nil
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

    @Test("A row whose driver is not installed is flagged rather than left ready")
    func flagsMissingDrivers() {
        let envelope = RDSDiscoveryReconciler.envelope(for: [exportable()])
        let preview = ConnectionImportPreview(
            envelope: envelope,
            items: [ImportItem(connection: exportable(), status: .ready)]
        )

        let marked = RDSDiscoveryReconciler.markingMissingDrivers(preview) { typeId in
            typeId == DatabaseType.postgresql.rawValue ? "PostgreSQL" : nil
        }

        guard case .warnings(let messages) = marked.items[0].status else {
            Issue.record("expected a warning status")
            return
        }
        #expect(messages.first?.contains("PostgreSQL") == true)
    }

    @Test("A duplicate row keeps its duplicate status")
    func leavesDuplicatesAlone() {
        let envelope = RDSDiscoveryReconciler.envelope(for: [exportable()])
        let existingId = UUID()
        let preview = ConnectionImportPreview(
            envelope: envelope,
            items: [
                ImportItem(
                    connection: exportable(),
                    status: .duplicate(existingId: existingId, existingName: "orders")
                )
            ]
        )

        let marked = RDSDiscoveryReconciler.markingMissingDrivers(preview) { _ in "PostgreSQL" }

        guard case .duplicate(let id, _) = marked.items[0].status else {
            Issue.record("expected the duplicate status to survive")
            return
        }
        #expect(id == existingId)
    }

    @Test("Analysis flags a discovered row that matches a saved connection")
    func duplicateDetection() {
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
        let existingId = UUID()
        let preview = ConnectionImportAnalyzer.analyze(
            RDSDiscoveryReconciler.envelope(for: connections),
            existingConnections: [
                ConnectionDuplicateCandidate(
                    id: existingId,
                    name: "Orders production",
                    host: "orders.abc123.us-east-1.rds.amazonaws.com",
                    port: 5_432,
                    database: "orders",
                    username: "app_ro",
                    redisDatabase: nil
                )
            ],
            registeredTypeIds: [DatabaseType.postgresql.rawValue],
            fileExists: { _ in true }
        )

        guard case .duplicate(let id, let name) = preview.items[0].status else {
            Issue.record("expected a duplicate")
            return
        }
        #expect(id == existingId)
        #expect(name == "Orders production")
        #expect(preview.items[0].status.isSelectedByDefault == false)
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
