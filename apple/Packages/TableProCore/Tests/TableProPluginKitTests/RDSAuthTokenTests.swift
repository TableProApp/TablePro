import Foundation
@testable import TableProPluginKit
import Testing

struct RDSAuthTokenGeneratorTests {
    private let credentials = AWSCredentials(
        accessKeyId: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        sessionToken: nil
    )
    private let fixedDate = Date(timeIntervalSince1970: 1_440_938_160)

    // Signed at fixedDate by botocore 1.42.97 (generate_db_auth_token) and by a SigV4 script written
    // from the AWS spec; both gave these signatures.
    private static let vectorHost = "mydb.abc123.us-east-1.rds.amazonaws.com"
    private static let vectorToken = "mydb.abc123.us-east-1.rds.amazonaws.com:5432/?Action=connect&DBUser=iam_user"
        + "&X-Amz-Algorithm=AWS4-HMAC-SHA256"
        + "&X-Amz-Credential=AKIDEXAMPLE%2F20150830%2Fus-east-1%2Frds-db%2Faws4_request"
        + "&X-Amz-Date=20150830T123600Z&X-Amz-Expires=900&X-Amz-SignedHeaders=host"
        + "&X-Amz-Signature=ad0215c0a1ee37ec044c9a9f4eac788e0f258274ef4a5e53460c3c74c4e824ac"
    private static let vectorTokenWithSession = "mydb.abc123.us-east-1.rds.amazonaws.com:5432/?Action=connect&DBUser=iam_user"
        + "&X-Amz-Algorithm=AWS4-HMAC-SHA256"
        + "&X-Amz-Credential=AKIDEXAMPLE%2F20150830%2Fus-east-1%2Frds-db%2Faws4_request"
        + "&X-Amz-Date=20150830T123600Z&X-Amz-Expires=900&X-Amz-Security-Token=FQoGZXIvYXdzEXAMPLE"
        + "&X-Amz-SignedHeaders=host"
        + "&X-Amz-Signature=517415e469bb2865f3347f18d1da5359f2694c79f7522598609c60836479f868"

    private func makeToken(host: String = "mydb.us-east-1.rds.amazonaws.com", sessionToken: String? = nil) -> String {
        RDSAuthTokenGenerator.generateToken(
            host: host,
            port: 5_432,
            region: "us-east-1",
            username: "iam_user",
            credentials: AWSCredentials(
                accessKeyId: credentials.accessKeyId,
                secretAccessKey: credentials.secretAccessKey,
                sessionToken: sessionToken
            ),
            now: fixedDate
        )
    }

    @Test("Token has the documented shape and no scheme")
    func tokenShape() {
        let token = makeToken()
        #expect(!token.hasPrefix("https://"))
        #expect(token.hasPrefix("mydb.us-east-1.rds.amazonaws.com:5432/?"))
        #expect(token.contains("Action=connect"))
        #expect(token.contains("DBUser=iam_user"))
        #expect(token.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"))
        #expect(token.contains("X-Amz-Expires=900"))
        #expect(token.contains("X-Amz-Credential=AKIDEXAMPLE%2F"))
        #expect(token.contains("%2Frds-db%2Faws4_request"))
        #expect(token.contains("X-Amz-Signature="))
    }

    @Test("Same inputs produce the same token")
    func deterministic() {
        let first = makeToken()
        let second = makeToken()
        #expect(first == second)
    }

    @Test("Session token is included only for temporary credentials")
    func sessionToken() {
        #expect(!makeToken().contains("X-Amz-Security-Token"))
        #expect(makeToken(sessionToken: "FQoGZXIvYXdzEXAMPLE").contains("X-Amz-Security-Token=FQoGZXIvYXdzEXAMPLE"))
    }

    @Test("The token matches one signed by an independent SigV4 implementation")
    func matchesIndependentVector() {
        #expect(makeToken(host: Self.vectorHost) == Self.vectorToken)
        #expect(makeToken(host: Self.vectorHost, sessionToken: "FQoGZXIvYXdzEXAMPLE") == Self.vectorTokenWithSession)
    }

    @Test("A host typed with capitals signs as the lowercase endpoint")
    func mixedCaseHostSignsLowercase() {
        #expect(makeToken(host: "MyDB.ABC123.us-east-1.RDS.AmazonAWS.com") == Self.vectorToken)
    }
}

struct RDSEndpointTests {
    @Test("Derives region from cluster hostname")
    func clusterHostname() {
        #expect(RDSEndpoint.region(forHost: "mydb.cluster-abc123.us-east-1.rds.amazonaws.com") == "us-east-1")
    }

    @Test("Derives region from instance hostname")
    func instanceHostname() {
        #expect(RDSEndpoint.region(forHost: "mydb.abc123.us-west-2.rds.amazonaws.com") == "us-west-2")
    }

    @Test("Derives region from China partition hostname")
    func chinaHostname() {
        #expect(RDSEndpoint.region(forHost: "mydb.abc.cn-north-1.rds.amazonaws.com.cn") == "cn-north-1")
    }

    @Test("Returns nil for non-RDS hosts")
    func nonRDSHost() {
        #expect(RDSEndpoint.region(forHost: "localhost") == nil)
        #expect(RDSEndpoint.region(forHost: "db.example.com") == nil)
    }

    @Test("Derives a lowercase region from a hostname typed with capitals")
    func mixedCaseHostname() {
        #expect(RDSEndpoint.region(forHost: "MyDB.abc123.US-EAST-1.RDS.AmazonAWS.com") == "us-east-1")
        #expect(RDSEndpoint.region(forHost: "MyDB.Cluster-ABC.EU-West-1.Rds.Amazonaws.Com") == "eu-west-1")
    }
}

struct RDSSigningEndpointResolverTests {
    private func resolve(
        host: String = "mydb.abc123.us-east-1.rds.amazonaws.com",
        port: Int = 5_432,
        preTunnelHost: String? = nil,
        preTunnelPort: Int? = nil,
        override: String? = nil,
        defaultPort: Int = 5_432
    ) throws -> RDSSigningEndpoint {
        try RDSSigningEndpointResolver.resolve(
            configuredHost: host,
            configuredPort: port,
            preTunnelHost: preTunnelHost,
            preTunnelPort: preTunnelPort,
            override: override,
            defaultPort: defaultPort
        )
    }

    @Test("A direct connection signs its own endpoint")
    func directConnection() throws {
        let endpoint = try resolve()
        #expect(endpoint == RDSSigningEndpoint(host: "mydb.abc123.us-east-1.rds.amazonaws.com", port: 5_432))
    }

    @Test("A tunneled connection signs the endpoint from before the rewrite")
    func tunneledConnection() throws {
        let endpoint = try resolve(
            host: "127.0.0.1",
            port: 62_000,
            preTunnelHost: "mydb.abc123.us-east-1.rds.amazonaws.com",
            preTunnelPort: 5_432
        )
        #expect(endpoint == RDSSigningEndpoint(host: "mydb.abc123.us-east-1.rds.amazonaws.com", port: 5_432))
    }

    @Test("The endpoint override wins over the tunnel and the configured host")
    func overrideWins() throws {
        let endpoint = try resolve(
            host: "127.0.0.1",
            port: 62_000,
            preTunnelHost: "old.abc123.us-east-1.rds.amazonaws.com",
            preTunnelPort: 5_432,
            override: "mydb.abc123.ap-south-1.rds.amazonaws.com:5433"
        )
        #expect(endpoint == RDSSigningEndpoint(host: "mydb.abc123.ap-south-1.rds.amazonaws.com", port: 5_433))
    }

    @Test("An override without a port falls back to the engine default")
    func overrideWithoutPort() throws {
        let endpoint = try resolve(
            host: "127.0.0.1",
            port: 54_321,
            override: "mydb.abc123.ap-south-1.rds.amazonaws.com",
            defaultPort: 5_432
        )
        #expect(endpoint == RDSSigningEndpoint(host: "mydb.abc123.ap-south-1.rds.amazonaws.com", port: 5_432))
    }

    @Test("A blank override is ignored")
    func blankOverrideIgnored() throws {
        let endpoint = try resolve(override: "   ")
        #expect(endpoint.host == "mydb.abc123.us-east-1.rds.amazonaws.com")
    }

    @Test("An override keeps only the host and port of a pasted URL")
    func overrideStripsSchemeAndPath() throws {
        let endpoint = try resolve(override: "postgresql://mydb.abc123.us-east-1.rds.amazonaws.com:5432/postgres")
        #expect(endpoint == RDSSigningEndpoint(host: "mydb.abc123.us-east-1.rds.amazonaws.com", port: 5_432))
    }

    @Test("A local forward with no override is rejected before the token is signed")
    func loopbackIsRejected() {
        for host in ["127.0.0.1", "localhost", "::1", "127.0.0.53"] {
            #expect(throws: AWSAuthError.rdsEndpointUnresolved(host: host)) {
                _ = try resolve(host: host, port: 54_321)
            }
        }
    }

    @Test("A tunnel to a loopback destination is rejected too")
    func loopbackPreTunnelHostIsRejected() {
        #expect(throws: AWSAuthError.rdsEndpointUnresolved(host: "localhost")) {
            _ = try resolve(host: "127.0.0.1", port: 62_000, preTunnelHost: "localhost", preTunnelPort: 5_432)
        }
    }

    @Test("A malformed override is rejected with the value the user typed")
    func malformedOverrideIsRejected() {
        for value in ["mydb.rds.amazonaws.com:port", "mydb.rds.amazonaws.com:0", ":5432", "127.0.0.1:5432"] {
            #expect(throws: AWSAuthError.rdsEndpointInvalid(value)) {
                _ = try resolve(override: value)
            }
        }
    }

    @Test("An override may not redirect the token away from the host being dialled")
    func overrideCannotRedirectToAnotherHost() {
        #expect(throws: AWSAuthError.rdsEndpointUnresolved(host: "evil.example.com")) {
            _ = try resolve(
                host: "evil.example.com",
                port: 5_432,
                override: "prod.abc123.us-east-1.rds.amazonaws.com:5432"
            )
        }
    }

    @Test("An override that restates the dialled host is accepted")
    func overrideMatchingDialledHostIsAccepted() throws {
        let endpoint = try resolve(
            host: "mydb.abc123.us-east-1.rds.amazonaws.com",
            port: 5_432,
            override: "MyDB.abc123.us-east-1.RDS.amazonaws.com:5433"
        )
        #expect(endpoint.port == 5_433)
    }

    @Test("A pre-tunnel host is ignored when the socket is not a local forward")
    func preTunnelHostIgnoredForRemoteDial() throws {
        let endpoint = try resolve(
            host: "evil.example.com",
            port: 5_432,
            preTunnelHost: "prod.abc123.us-east-1.rds.amazonaws.com",
            preTunnelPort: 5_432
        )
        #expect(endpoint == RDSSigningEndpoint(host: "evil.example.com", port: 5_432))
    }

    @Test("The region comes from the signing host, not the local forward")
    func regionFollowsSigningHost() throws {
        let endpoint = try resolve(
            host: "127.0.0.1",
            port: 62_000,
            preTunnelHost: "mydb.abc123.ap-south-1.rds.amazonaws.com",
            preTunnelPort: 5_432
        )
        #expect(RDSEndpoint.region(forHost: endpoint.host) == "ap-south-1")
    }

    @Test("A host typed with capitals resolves to the lowercase endpoint")
    func mixedCaseHostResolvesLowercase() throws {
        let lowercase = RDSSigningEndpoint(host: "mydb.abc123.us-east-1.rds.amazonaws.com", port: 5_432)
        #expect(try resolve(host: "MyDB.abc123.US-EAST-1.rds.amazonaws.com") == lowercase)
        #expect(try resolve(
            host: "127.0.0.1",
            port: 62_000,
            preTunnelHost: "MyDB.abc123.US-EAST-1.rds.amazonaws.com",
            preTunnelPort: 5_432
        ) == lowercase)
        #expect(try resolve(host: "127.0.0.1", port: 62_000, override: "MyDB.abc123.US-EAST-1.RDS.amazonaws.com:5432") == lowercase)
    }
}
