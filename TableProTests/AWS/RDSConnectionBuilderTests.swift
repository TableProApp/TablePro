import Foundation
@testable import TablePro
import TableProImport
import TableProPluginKit
import Testing

@Suite("RDS connection building")
struct RDSConnectionBuilderTests {
    private static let iamAuthentication = AWSDiscoveryAuthentication(
        mode: .iam,
        awsAuthValue: "sso",
        profileName: "corp"
    )

    private func database(
        identifier: String = "orders",
        kind: DiscoveredDatabaseKind = .instance,
        engine: String = "postgres",
        host: String? = "orders.abc123.us-east-1.rds.amazonaws.com",
        port: Int? = 5_432,
        databaseName: String? = "orders",
        adminUsername: String? = "postgres",
        iam: Bool = true,
        region: String = "us-east-1"
    ) -> DiscoveredDatabase {
        DiscoveredDatabase(
            region: region,
            identifier: identifier,
            kind: kind,
            engine: engine,
            engineVersion: nil,
            status: "available",
            host: host,
            port: port,
            databaseName: databaseName,
            adminUsername: adminUsername,
            iamAuthenticationEnabled: iam,
            isPubliclyAccessible: false
        )
    }

    @Test("An IAM-enabled database carries the profile, region and auth mode")
    func iamPrefill() throws {
        var taken: Set<String> = []
        let connection = try #require(
            RDSConnectionBuilder.exportable(
                for: database(),
                authentication: Self.iamAuthentication,
                takenNames: &taken
            )
        )

        #expect(connection.name == "orders")
        #expect(connection.host == "orders.abc123.us-east-1.rds.amazonaws.com")
        #expect(connection.port == 5_432)
        #expect(connection.database == "orders")
        #expect(connection.type == DatabaseType.postgresql.rawValue)
        #expect(connection.additionalFields?["awsAuth"] == "sso")
        #expect(connection.additionalFields?["awsRegion"] == "us-east-1")
        #expect(connection.additionalFields?["awsProfileName"] == "corp")
        #expect(connection.additionalFields?["promptForPassword"] == nil)
        #expect(connection.additionalFields?["awsRDSEndpoint"] == nil)
        #expect(connection.sslConfig?.mode == SSLMode.required.rawValue)
    }

    @Test("An IAM row keeps its username empty, because the IAM role is not the RDS admin user")
    func usernameStaysEmptyForIAM() throws {
        var taken: Set<String> = []
        let connection = try #require(
            RDSConnectionBuilder.exportable(
                for: database(adminUsername: "postgres"),
                authentication: Self.iamAuthentication,
                takenNames: &taken
            )
        )
        #expect(connection.username.isEmpty)
    }

    @Test("A password row keeps the admin username, which the password prompt cannot supply")
    func usernameKeptForPassword() throws {
        var taken: Set<String> = []
        let connection = try #require(
            RDSConnectionBuilder.exportable(
                for: database(adminUsername: "postgres", iam: false),
                authentication: Self.iamAuthentication,
                takenNames: &taken
            )
        )
        #expect(connection.username == "postgres")
        #expect(connection.sslConfig?.mode == SSLMode.required.rawValue)
    }

    @Test("A database without IAM authentication asks for a password instead")
    func passwordFallback() throws {
        var taken: Set<String> = []
        let connection = try #require(
            RDSConnectionBuilder.exportable(
                for: database(iam: false),
                authentication: Self.iamAuthentication,
                takenNames: &taken
            )
        )
        #expect(connection.additionalFields?["awsAuth"] == "off")
        #expect(connection.additionalFields?["promptForPassword"] == "true")
        #expect(connection.additionalFields?["awsProfileName"] == nil)
    }

    @Test("Password mode never writes an IAM auth method")
    func passwordMode() throws {
        var taken: Set<String> = []
        let connection = try #require(
            RDSConnectionBuilder.exportable(
                for: database(iam: true),
                authentication: AWSDiscoveryAuthentication(mode: .password, awsAuthValue: "profile", profileName: "corp"),
                takenNames: &taken
            )
        )
        #expect(connection.additionalFields?["awsAuth"] == "off")
        #expect(connection.additionalFields?["promptForPassword"] == "true")
    }

    @Test("A row with no endpoint, no port, or an unmapped engine builds nothing")
    func unbuildableRows() {
        var taken: Set<String> = []
        #expect(
            RDSConnectionBuilder.exportable(
                for: database(host: nil),
                authentication: Self.iamAuthentication,
                takenNames: &taken
            ) == nil
        )
        #expect(
            RDSConnectionBuilder.exportable(
                for: database(port: nil),
                authentication: Self.iamAuthentication,
                takenNames: &taken
            ) == nil
        )
        #expect(
            RDSConnectionBuilder.exportable(
                for: database(port: 70_000),
                authentication: Self.iamAuthentication,
                takenNames: &taken
            ) == nil
        )
        #expect(
            RDSConnectionBuilder.exportable(
                for: database(engine: "neptune"),
                authentication: Self.iamAuthentication,
                takenNames: &taken
            ) == nil
        )
    }

    @Test("A host from the API is validated before it becomes a saved connection")
    func hostValidation() {
        #expect(RDSConnectionBuilder.validatedHost("db.abc.us-east-1.rds.amazonaws.com") != nil)
        #expect(RDSConnectionBuilder.validatedHost("localhost") == nil)
        #expect(RDSConnectionBuilder.validatedHost("db.example.com\nrm -rf") == nil)
        #expect(RDSConnectionBuilder.validatedHost("db .example.com") == nil)
        #expect(RDSConnectionBuilder.validatedHost("db..example.com") == nil)
        #expect(RDSConnectionBuilder.validatedHost("") == nil)
        #expect(RDSConnectionBuilder.validatedHost(nil) == nil)
        #expect(RDSConnectionBuilder.validatedHost(String(repeating: "a", count: 250) + ".com") == nil)
    }

    @Test("Names are unique within the batch and against saved connections")
    func naming() {
        let databases = [
            database(identifier: "orders", region: "us-east-1"),
            database(identifier: "orders", region: "eu-west-1"),
            database(identifier: "analytics", kind: .clusterWriter, engine: "aurora-mysql", port: 3_306),
            database(identifier: "analytics", kind: .clusterReader, engine: "aurora-mysql", port: 3_306)
        ]
        let connections = RDSConnectionBuilder.exportables(
            for: databases,
            authentication: Self.iamAuthentication,
            existingNames: ["Orders"]
        )

        #expect(connections.map(\.name) == [
            "orders (us-east-1)",
            "orders (eu-west-1)",
            "analytics",
            "analytics (reader)"
        ])
    }
}
