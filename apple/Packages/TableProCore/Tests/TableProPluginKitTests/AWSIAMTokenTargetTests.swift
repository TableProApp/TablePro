import Foundation
import TableProPluginKit
import Testing

struct AWSIAMTokenTargetTests {
    private let credentials = AWSCredentials(
        accessKeyId: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        sessionToken: nil
    )
    private let fixedDate = Date(timeIntervalSince1970: 1_440_938_160)
    private let cacheHost = "my-cache.abc123.use1.cache.amazonaws.com"
    private let cacheFields = ["awsRegion": "us-east-1", "awsReplicationGroupId": "my-cache"]

    private func token(_ target: AWSIAMTokenTarget, fields: [String: String] = [:]) throws -> String {
        try target.token(username: "iam_user", fields: fields, credentials: credentials, now: fixedDate)
    }

    private func rds(
        host: String = "mydb.abc123.us-east-1.rds.amazonaws.com",
        port: Int = 5_432,
        preTunnelHost: String? = nil,
        preTunnelPort: Int? = nil
    ) -> AWSIAMTokenTarget {
        .rds(
            configuredHost: host,
            configuredPort: port,
            preTunnelHost: preTunnelHost,
            preTunnelPort: preTunnelPort,
            defaultPort: 5_432
        )
    }

    @Test("Redis with SSL off throws the requires-TLS error")
    func elastiCacheWithTLSOffThrows() {
        let requiresTLS = AWSAuthError.missingConfiguration(
            String(localized: "ElastiCache IAM authentication requires TLS. Enable SSL in the connection's SSL settings.")
        )
        #expect(throws: requiresTLS) {
            _ = try token(.elastiCache(host: cacheHost, tlsDisabled: true), fields: cacheFields)
        }
    }

    @Test("Redis with SSL on signs the cache name")
    func elastiCacheWithTLSOnSigns() throws {
        let expected = ElastiCacheAuthTokenGenerator.generateToken(
            replicationGroupId: "my-cache",
            region: "us-east-1",
            userId: "iam_user",
            credentials: credentials,
            now: fixedDate
        )
        #expect(try token(.elastiCache(host: cacheHost, tlsDisabled: false), fields: cacheFields) == expected)
    }

    @Test("ElastiCache asks for the region before TLS, and for the cache name after it")
    func elastiCacheCheckOrder() {
        #expect(throws: AWSAuthError.regionUnknown(host: cacheHost)) {
            _ = try token(.elastiCache(host: cacheHost, tlsDisabled: true), fields: ["awsReplicationGroupId": "my-cache"])
        }
        let missingCacheName = AWSAuthError.missingConfiguration(
            String(localized: "Enter the ElastiCache cache name (replication group ID) to use IAM authentication.")
        )
        #expect(throws: missingCacheName) {
            _ = try token(.elastiCache(host: cacheHost, tlsDisabled: false), fields: ["awsRegion": "us-east-1"])
        }
    }

    @Test("A tunneled RDS connection signs the endpoint from before the tunnel")
    func rdsTunneledSignsPreTunnelHost() throws {
        let tunneled = try token(rds(
            host: "127.0.0.1",
            port: 62_000,
            preTunnelHost: "mydb.abc123.us-east-1.rds.amazonaws.com",
            preTunnelPort: 5_432
        ))
        let direct = try token(rds())
        #expect(tunneled == direct)
        #expect(tunneled.hasPrefix("mydb.abc123.us-east-1.rds.amazonaws.com:5432/?Action=connect&DBUser=iam_user&"))
    }

    @Test("A host typed with capitals finds its region and signs as the lowercase endpoint")
    func rdsMixedCaseHost() throws {
        let mixedCase = try token(rds(host: "MyDB.abc123.US-EAST-1.RDS.amazonaws.com"))
        let lowercase = try token(rds())
        #expect(mixedCase == lowercase)
    }

    @Test("The AWS Region field wins over the region in the host")
    func rdsExplicitRegionWins() throws {
        let signed = try token(rds(), fields: ["awsRegion": "eu-west-1"])
        #expect(signed.contains("%2Feu-west-1%2Frds-db%2Faws4_request"))
    }

    @Test("A host with no region and no AWS Region field is rejected")
    func rdsRegionUnknown() {
        #expect(throws: AWSAuthError.regionUnknown(host: "db.example.com")) {
            _ = try token(rds(host: "db.example.com"))
        }
    }

    @Test("A local forward with no RDS Endpoint is rejected")
    func rdsLoopbackRejected() {
        #expect(throws: AWSAuthError.rdsEndpointUnresolved(host: "127.0.0.1")) {
            _ = try token(rds(host: "127.0.0.1", port: 54_321))
        }
    }

    @Test("The RDS Endpoint field signs the endpoint behind a local forward")
    func rdsEndpointOverride() throws {
        let signed = try token(
            rds(host: "127.0.0.1", port: 54_321),
            fields: ["awsRDSEndpoint": "mydb.abc123.ap-south-1.rds.amazonaws.com:5433"]
        )
        #expect(signed.hasPrefix("mydb.abc123.ap-south-1.rds.amazonaws.com:5433/?"))
        #expect(signed.contains("%2Fap-south-1%2Frds-db%2Faws4_request"))
    }
}
