import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

struct AWSIAMTokenSignerTests {
    private static let accessKeyFields = [
        "awsAuth": "accessKey",
        "awsAccessKeyId": "AKIDEXAMPLE",
        "awsSecretAccessKey": "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    ]
    private static let rdsHost = "mydb.abc123.us-east-1.rds.amazonaws.com"
    private static let cacheHost = "my-cache.abc123.use1.cache.amazonaws.com"

    private func makeSigner(
        for connection: DatabaseConnection,
        fields: [String: String] = AWSIAMTokenSignerTests.accessKeyFields
    ) -> AWSIAMTokenSigner {
        AWSIAMTokenSigner(connection: connection, source: "accessKey", username: "iam_user", fields: fields)
    }

    private func tunneledPostgreSQL() -> DatabaseConnection {
        DatabaseConnection(
            name: "rds",
            host: "127.0.0.1",
            port: 62_000,
            username: "iam_user",
            type: .postgresql,
            additionalFields: [
                DatabaseConnection.preTunnelHostKey: Self.rdsHost,
                DatabaseConnection.preTunnelPortKey: "5432"
            ]
        )
    }

    private func redis(sslMode: SSLMode) -> DatabaseConnection {
        DatabaseConnection(
            name: "cache",
            host: Self.cacheHost,
            port: 6_379,
            username: "iam_user",
            type: .redis,
            sslConfig: SSLConfiguration(mode: sslMode)
        )
    }

    private var cacheFields: [String: String] {
        Self.accessKeyFields.merging(["awsRegion": "us-east-1", "awsReplicationGroupId": "my-cache"]) { _, new in new }
    }

    @Test("A tunneled PostgreSQL connection signs the endpoint from before the tunnel")
    func tunneledPostgreSQLSignsPreTunnelHost() async throws {
        let signer = makeSigner(for: tunneledPostgreSQL())
        #expect(signer.target == .rds(
            configuredHost: "127.0.0.1",
            configuredPort: 62_000,
            preTunnelHost: Self.rdsHost,
            preTunnelPort: 5_432,
            defaultPort: 5_432
        ))

        let token = try await signer.token(deadline: nil)
        #expect(token.hasPrefix("\(Self.rdsHost):5432/?Action=connect&DBUser=iam_user&"))
        #expect(token.contains("X-Amz-Credential=AKIDEXAMPLE%2F"))
        #expect(token.contains("%2Fus-east-1%2Frds-db%2Faws4_request"))
    }

    @Test("Redis with SSL off throws the requires-TLS error")
    func redisWithSSLOffThrowsTLSError() async {
        let signer = makeSigner(for: redis(sslMode: .disabled), fields: cacheFields)
        #expect(signer.target == .elastiCache(host: Self.cacheHost, tlsDisabled: true))

        let requiresTLS = AWSAuthError.missingConfiguration(
            String(localized: "ElastiCache IAM authentication requires TLS. Enable SSL in the connection's SSL settings.")
        )
        await #expect(throws: requiresTLS) {
            _ = try await signer.token(deadline: nil)
        }
    }

    @Test("Redis with SSL on signs the cache name")
    func redisWithSSLOnSigns() async throws {
        let signer = makeSigner(for: redis(sslMode: .required), fields: cacheFields)
        #expect(signer.target == .elastiCache(host: Self.cacheHost, tlsDisabled: false))

        let token = try await signer.token(deadline: nil)
        #expect(token.hasPrefix("my-cache/?Action=connect&User=iam_user&"))
    }
}
