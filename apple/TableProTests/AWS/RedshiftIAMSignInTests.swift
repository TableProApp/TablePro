//
//  RedshiftIAMSignInTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct RedshiftIAMSignInTests {
    private static let clusterHost = "analytics.abc123xyz.us-east-1.redshift.amazonaws.com"
    private static let serverlessHost = "reporting.123456789012.eu-west-1.redshift-serverless.amazonaws.com"
    private static let credentials = AWSCredentials(
        accessKeyId: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        sessionToken: nil,
        expiration: nil
    )
    private static let signedAt = Date(timeIntervalSince1970: 1_792_544_523)

    private static func signIn(
        user: String = "",
        host: String = clusterHost,
        preTunnelHost: String? = nil,
        fields: [String: String] = ["awsAuth": "profile"],
        aliases: FakeCNAMEResolver = FakeCNAMEResolver()
    ) -> RedshiftIAMSignIn {
        RedshiftIAMSignIn(
            source: "profile",
            databaseUser: user,
            database: "dev",
            fields: fields,
            configuredHost: host,
            preTunnelHost: preTunnelHost,
            aliasResolver: aliases
        )
    }

    private static func formParameters(_ request: URLRequest) -> [String: String] {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        var parameters: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
            parameters[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return parameters
    }

    @Test("An AWS Region field that would name another host is refused before anything is signed", arguments: [
        "attacker.example/",
        "x@attacker.example#",
    ])
    func regionNamingAnotherHostIsRefused(region: String) {
        let cluster = RedshiftIAMSignIn.Endpoint.cluster(identifier: "analytics", region: "us-east-1")
        let workgroup = RedshiftIAMSignIn.Endpoint.serverless(workgroup: "reporting", region: "eu-west-1")
        for endpoint in [cluster, workgroup] {
            #expect(throws: AWSAuthError.self) {
                try Self.signIn(fields: ["awsAuth": "profile", "awsRegion": region])
                    .request(for: endpoint, region: region, credentials: Self.credentials)
            }
        }
    }

    @Test("Cluster and workgroup endpoints name what to ask for and where")
    func endpointsParse() {
        #expect(RedshiftIAMSignIn.endpoint(forHost: Self.clusterHost) == .cluster(identifier: "analytics", region: "us-east-1"))
        #expect(RedshiftIAMSignIn.endpoint(forHost: Self.serverlessHost) == .serverless(workgroup: "reporting", region: "eu-west-1"))
        #expect(
            RedshiftIAMSignIn.endpoint(forHost: "bi.abc.cn-north-1.redshift.amazonaws.com.cn")
                == .cluster(identifier: "bi", region: "cn-north-1")
        )
        #expect(RedshiftIAMSignIn.endpoint(forHost: "127.0.0.1") == nil)
        #expect(RedshiftIAMSignIn.endpoint(forHost: "redshift.example.com") == nil)
    }

    @Test("A lookalike host never gets credentials minted for a real cluster", arguments: [
        "analytics.attacker.us-east-1.redshift.amazonaws.com.evil.example",
        "analytics.attacker.us-east-1.redshift.amazonaws-evil.com",
        "analytics.abc.us-east-1.redshift.amazonaws.com.cn",
        "a.analytics.abc.us-east-1.redshift.amazonaws.com",
        "analytics..us-east-1.redshift.amazonaws.com"
    ])
    func lookalikesAreRefused(host: String) {
        #expect(RedshiftIAMSignIn.endpoint(forHost: host) == nil)
    }

    @Test("A tunneled connection signs in for the endpoint typed before the tunnel")
    func tunneledConnectionUsesPreTunnelHost() async throws {
        let tunneled = Self.signIn(host: "127.0.0.1", preTunnelHost: Self.clusterHost)
        #expect(try await tunneled.resolveEndpoint(within: nil) == .cluster(identifier: "analytics", region: "us-east-1"))
    }

    @Test("The Redshift Endpoint field names a forward's target, and a host that names nothing says what to enter")
    func endpointOverride() async throws {
        let forwarded = Self.signIn(
            host: "127.0.0.1",
            fields: ["awsAuth": "sso", RedshiftIAMSignIn.endpointFieldId: "https://\(Self.serverlessHost):5439/dev"]
        )
        #expect(try await forwarded.resolveEndpoint(within: nil) == .serverless(workgroup: "reporting", region: "eu-west-1"))

        let otherCluster = Self.signIn(
            host: "other.abc123xyz.us-east-1.redshift.amazonaws.com",
            fields: [RedshiftIAMSignIn.endpointFieldId: Self.serverlessHost]
        )
        await #expect(throws: RedshiftIAMError.endpointNotDialed(host: "other.abc123xyz.us-east-1.redshift.amazonaws.com")) {
            try await otherCluster.resolveEndpoint(within: nil)
        }

        await #expect(throws: RedshiftIAMError.endpointNotDialed(host: "10.0.0.5")) {
            try await Self.signIn(host: "10.0.0.5", fields: [RedshiftIAMSignIn.endpointFieldId: Self.clusterHost])
                .resolveEndpoint(within: nil)
        }

        await #expect(throws: RedshiftIAMError.endpointUnresolved(host: "warehouse.corp.example")) {
            try await Self.signIn(host: "warehouse.corp.example").resolveEndpoint(within: nil)
        }
        await #expect(throws: RedshiftIAMError.endpointInvalid("not-an-endpoint")) {
            try await Self.signIn(host: "localhost", fields: [RedshiftIAMSignIn.endpointFieldId: "not-an-endpoint"])
                .resolveEndpoint(within: nil)
        }
    }

    @Test("A custom domain Host is asked for by name, with the kind and region from the Redshift Endpoint field")
    func customDomainWithEndpointField() async throws {
        let serverless = Self.signIn(
            host: "Warehouse.Corp.Example.",
            fields: [RedshiftIAMSignIn.endpointFieldId: Self.serverlessHost]
        )
        #expect(try await serverless.resolveEndpoint(within: nil)
            == .serverlessDomain(name: "warehouse.corp.example", region: "eu-west-1"))

        let cluster = Self.signIn(host: "warehouse.corp.example", fields: [RedshiftIAMSignIn.endpointFieldId: Self.clusterHost])
        #expect(try await cluster.resolveEndpoint(within: nil) == .clusterDomain(name: "warehouse.corp.example", region: "us-east-1"))
    }

    @Test("A custom domain Host finds its kind and region through its CNAME, and is still asked for by name")
    func customDomainThroughCNAME() async throws {
        let aliases = FakeCNAMEResolver([
            "warehouse.corp.example": "edge.corp.example",
            "edge.corp.example": Self.clusterHost
        ])
        let direct = Self.signIn(host: "warehouse.corp.example", aliases: aliases)
        #expect(try await direct.resolveEndpoint(within: nil) == .clusterDomain(name: "warehouse.corp.example", region: "us-east-1"))

        let tunneled = Self.signIn(
            host: "127.0.0.1",
            preTunnelHost: "bi.corp.example",
            aliases: FakeCNAMEResolver(["bi.corp.example": Self.serverlessHost])
        )
        #expect(try await tunneled.resolveEndpoint(within: nil) == .serverlessDomain(name: "bi.corp.example", region: "eu-west-1"))
    }

    @Test("A DNS name that starts like 127.0.0.1 is not a forward, so the endpoint field cannot point it at a real cluster")
    func loopbackLookalikeIsACustomDomain() async throws {
        let fields = [RedshiftIAMSignIn.endpointFieldId: Self.clusterHost]
        #expect(try await Self.signIn(host: "127.0.0.1.attacker.example", fields: fields).resolveEndpoint(within: nil)
            == .clusterDomain(name: "127.0.0.1.attacker.example", region: "us-east-1"))
        await #expect(throws: RedshiftIAMError.endpointNotDialed(host: "127.0.0.1.")) {
            try await Self.signIn(host: "127.0.0.1.", fields: fields).resolveEndpoint(within: nil)
        }
    }

    @Test("A custom domain asks by CustomDomainName, never by the cluster or workgroup name")
    func customDomainRequests() throws {
        let cluster = try Self.signIn(user: "reporting").request(
            for: .clusterDomain(name: "warehouse.corp.example", region: "us-east-1"),
            region: "us-east-1",
            credentials: Self.credentials
        )
        #expect(Self.formParameters(cluster) == [
            "Action": "GetClusterCredentials",
            "Version": "2012-12-01",
            "CustomDomainName": "warehouse.corp.example",
            "DbUser": "reporting",
            "DbName": "dev"
        ])

        let serverless = try Self.signIn().request(
            for: .serverlessDomain(name: "bi.corp.example", region: "eu-west-1"),
            region: "eu-west-1",
            credentials: Self.credentials,
            now: Self.signedAt
        )
        #expect(serverless.value(forHTTPHeaderField: "x-amz-target") == "RedshiftServerless.GetCredentials")
        #expect(String(data: serverless.httpBody ?? Data(), encoding: .utf8) == #"{"customDomainName":"bi.corp.example","dbName":"dev"}"#)
    }

    @Test("A cluster with a database user asks GetClusterCredentials, without one GetClusterCredentialsWithIAM")
    func clusterRequests() throws {
        let endpoint = RedshiftIAMSignIn.Endpoint.cluster(identifier: "analytics", region: "us-east-1")

        let withUser = try Self.signIn(user: "reporting").request(for: endpoint, region: "us-east-1", credentials: Self.credentials)
        #expect(withUser.url?.host == "redshift.us-east-1.amazonaws.com")
        #expect(Self.formParameters(withUser) == [
            "Action": "GetClusterCredentials",
            "Version": "2012-12-01",
            "ClusterIdentifier": "analytics",
            "DbUser": "reporting",
            "DbName": "dev"
        ])

        let asIdentity = try Self.signIn().request(for: endpoint, region: "us-east-1", credentials: Self.credentials)
        #expect(Self.formParameters(asIdentity) == [
            "Action": "GetClusterCredentialsWithIAM",
            "Version": "2012-12-01",
            "ClusterIdentifier": "analytics",
            "DbName": "dev"
        ])
        #expect(asIdentity.value(forHTTPHeaderField: "Authorization")?.contains("/us-east-1/redshift/aws4_request") == true)
    }

    @Test("A Serverless workgroup asks GetCredentials over a signed JSON request")
    func serverlessRequest() throws {
        let endpoint = RedshiftIAMSignIn.Endpoint.serverless(workgroup: "analytics", region: "us-east-1")
        let request = try Self.signIn(user: "ignored").request(
            for: endpoint,
            region: "us-east-1",
            credentials: Self.credentials,
            now: Self.signedAt
        )

        #expect(request.url?.absoluteString == "https://redshift-serverless.us-east-1.amazonaws.com/")
        #expect(request.value(forHTTPHeaderField: "x-amz-target") == "RedshiftServerless.GetCredentials")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/x-amz-json-1.1")
        #expect(String(data: request.httpBody ?? Data(), encoding: .utf8) == #"{"dbName":"dev","workgroupName":"analytics"}"#)
        // Signature computed independently with Python's hmac and hashlib.
        #expect(request.value(forHTTPHeaderField: "Authorization") == """
            AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261021/us-east-1/redshift-serverless/aws4_request, \
            SignedHeaders=content-type;host;x-amz-date;x-amz-target, \
            Signature=36b797213e939c77bfc2b589b4a39e541e9a99f312f3425aba20a15b9c2567ea
            """)
    }

    @Test("The user and password come from the AWS answer")
    func responsesParse() throws {
        let clusterXML = """
            <GetClusterCredentialsWithIAMResponse xmlns="http://redshift.amazonaws.com/doc/2012-12-01/">
              <GetClusterCredentialsWithIAMResult>
                <DbUser>IAMR:analyst</DbUser>
                <Expiration>2026-10-21T01:17:03.001Z</Expiration>
                <DbPassword>AMAFUyyuros/QjxPTtgzcsuQsqzIasdzJEN04aCtWDzXx1O9d6Ump==</DbPassword>
              </GetClusterCredentialsWithIAMResult>
            </GetClusterCredentialsWithIAMResponse>
            """
        #expect(
            try RedshiftIAMSignIn.signIn(from: Data(clusterXML.utf8), for: .cluster(identifier: "a", region: "r"))
                == ResolvedSignIn(username: "IAMR:analyst", password: "AMAFUyyuros/QjxPTtgzcsuQsqzIasdzJEN04aCtWDzXx1O9d6Ump==")
        )

        let serverlessJSON = #"{"dbPassword":"secret","dbUser":"IAM:alice","expiration":1792545423.0}"#
        #expect(
            try RedshiftIAMSignIn.signIn(from: Data(serverlessJSON.utf8), for: .serverless(workgroup: "w", region: "r"))
                == ResolvedSignIn(username: "IAM:alice", password: "secret")
        )

        #expect(throws: RedshiftIAMError.unreadableResponse) {
            try RedshiftIAMSignIn.signIn(from: Data("{}".utf8), for: .serverless(workgroup: "w", region: "r"))
        }
    }

    @Test("An AWS refusal names its code and message")
    func errorsParse() {
        let queryError = """
            <ErrorResponse><Error><Code>ClusterNotFound</Code><Message>Cluster analytics not found.</Message></Error></ErrorResponse>
            """
        #expect(
            RedshiftIAMSignIn.errorMessage(in: Data(queryError.utf8), for: .cluster(identifier: "a", region: "r"))
                == "ClusterNotFound: Cluster analytics not found."
        )
        let jsonError = #"{"__type":"com.amazonaws.redshiftserverless#ResourceNotFoundException","message":"Workgroup not found"}"#
        #expect(
            RedshiftIAMSignIn.errorMessage(in: Data(jsonError.utf8), for: .serverless(workgroup: "w", region: "r"))
                == "ResourceNotFoundException: Workgroup not found"
        )
    }

    @Test("A Redshift connection on AWS IAM signs in through Redshift, and a password one does not")
    func minterRouting() {
        var redshift = DatabaseConnection(
            name: "warehouse",
            host: Self.clusterHost,
            port: 5_439,
            database: "dev",
            username: "reporting",
            type: .redshift,
            additionalFields: ["awsAuth": "sso", "awsProfileName": "analytics"]
        )
        guard case .redshift(let signIn) = ConnectionCredentialResolver.iamPasswordMinter(
            for: redshift,
            fields: redshift.additionalFields
        ) else {
            Issue.record("Expected the Redshift sign-in")
            return
        }
        #expect(signIn.source == "sso")
        #expect(signIn.databaseUser == "reporting")
        #expect(signIn.database == "dev")
        #expect(redshift.transportSSLConfiguration.mode == .required)

        redshift.additionalFields["awsAuth"] = "off"
        #expect(ConnectionCredentialResolver.iamPasswordMinter(for: redshift, fields: redshift.additionalFields) == nil)
    }
}
