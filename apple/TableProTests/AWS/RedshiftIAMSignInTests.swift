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
        fields: [String: String] = ["awsAuth": "profile"]
    ) -> RedshiftIAMSignIn {
        RedshiftIAMSignIn(
            source: "profile",
            databaseUser: user,
            database: "dev",
            fields: fields,
            configuredHost: host,
            preTunnelHost: preTunnelHost
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
    func tunneledConnectionUsesPreTunnelHost() throws {
        let tunneled = Self.signIn(host: "127.0.0.1", preTunnelHost: Self.clusterHost)
        #expect(try tunneled.resolveEndpoint() == .cluster(identifier: "analytics", region: "us-east-1"))
    }

    @Test("The Redshift Endpoint field names a forward's target, and a host that names nothing says what to enter")
    func endpointOverride() throws {
        let forwarded = Self.signIn(
            host: "127.0.0.1",
            fields: ["awsAuth": "sso", RedshiftIAMSignIn.endpointFieldId: "https://\(Self.serverlessHost):5439/dev"]
        )
        #expect(try forwarded.resolveEndpoint() == .serverless(workgroup: "reporting", region: "eu-west-1"))

        let elsewhere = Self.signIn(
            host: "warehouse.corp.example",
            fields: [RedshiftIAMSignIn.endpointFieldId: Self.serverlessHost]
        )
        #expect(throws: RedshiftIAMError.endpointNotDialed(host: "warehouse.corp.example")) {
            try elsewhere.resolveEndpoint()
        }

        #expect(throws: RedshiftIAMError.endpointUnresolved(host: "warehouse.corp.example")) {
            try Self.signIn(host: "warehouse.corp.example").resolveEndpoint()
        }
        #expect(throws: RedshiftIAMError.endpointInvalid("not-an-endpoint")) {
            try Self.signIn(host: "localhost", fields: [RedshiftIAMSignIn.endpointFieldId: "not-an-endpoint"]).resolveEndpoint()
        }
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
