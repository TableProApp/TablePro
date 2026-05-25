//
//  AWSIAMAuthTests.swift
//  TableProTests
//
//  Covers the pure, deterministic parts of RDS IAM authentication: the SigV4
//  primitives against published test vectors, the presigned token structure,
//  region derivation from RDS hostnames, the access-key credential resolver,
//  and the AWS config INI parser. Profile/SSO resolution and the live SSO
//  network exchange require the filesystem/AWS and are not unit-tested.
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("AWS SigV4 primitives")
struct AWSSigV4Tests {
    @Test("SHA-256 matches NIST vectors")
    func sha256Vectors() {
        #expect(AWSSigV4.sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(AWSSigV4.sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("HMAC-SHA256 matches RFC 4231 test case 1")
    func hmacVector() {
        let key = Data(repeating: 0x0b, count: 20)
        let data = Data("Hi There".utf8)
        #expect(AWSSigV4.hmacHex(key: key, data: data) == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }

    @Test("URI encoding percent-encodes reserved characters")
    func uriEncoding() {
        #expect(AWSSigV4.uriEncode("a/b") == "a%2Fb")
        #expect(AWSSigV4.uriEncode("us-east-1/rds-db") == "us-east-1%2Frds-db")
        #expect(AWSSigV4.uriEncode("safe-._~AZ09") == "safe-._~AZ09")
    }
}

@Suite("RDS auth token")
struct RDSAuthTokenGeneratorTests {
    private let credentials = AWSCredentials(
        accessKeyId: "AKIDEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        sessionToken: nil
    )
    private let fixedDate = Date(timeIntervalSince1970: 1_440_938_160)

    private func makeToken(sessionToken: String? = nil) -> String {
        RDSAuthTokenGenerator.generateToken(
            host: "mydb.us-east-1.rds.amazonaws.com",
            port: 5432,
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
}

@Suite("RDS endpoint region")
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
}

@Suite("AWS credential resolver")
struct AWSCredentialResolverTests {
    @Test("Resolves static access-key credentials")
    func staticCredentials() async throws {
        let credentials = try await AWSCredentialResolver.resolve(
            source: "accessKey",
            fields: ["awsAccessKeyId": "AKID", "awsSecretAccessKey": "SECRET", "awsSessionToken": "TOKEN"]
        )
        #expect(credentials.accessKeyId == "AKID")
        #expect(credentials.secretAccessKey == "SECRET")
        #expect(credentials.sessionToken == "TOKEN")
    }

    @Test("Treats an empty session token as absent")
    func emptySessionToken() async throws {
        let credentials = try await AWSCredentialResolver.resolve(
            source: "accessKey",
            fields: ["awsAccessKeyId": "AKID", "awsSecretAccessKey": "SECRET", "awsSessionToken": ""]
        )
        #expect(credentials.sessionToken == nil)
    }

    @Test("Throws when access keys are missing")
    func missingKeys() async {
        await #expect(throws: AWSAuthError.missingAccessKey) {
            _ = try await AWSCredentialResolver.resolve(source: "accessKey", fields: [:])
        }
    }
}

@Suite("AWS config INI parsing")
struct AWSSSOParsingTests {
    private let config = """
    [default]
    region = us-east-1

    [profile dev]
    sso_session = my-sso
    sso_account_id = 111122223333
    sso_role_name = Developer

    [sso-session my-sso]
    sso_start_url = https://example.awsapps.com/start
    sso_region = us-east-1
    """

    @Test("Resolves a profile that references an sso-session")
    func profileWithSession() throws {
        let settings = try AWSSSO.parseProfileSettings(configContent: config, profileName: "dev")
        #expect(settings.accountId == "111122223333")
        #expect(settings.roleName == "Developer")
        #expect(settings.startUrl == "https://example.awsapps.com/start")
        #expect(settings.region == "us-east-1")
        #expect(settings.ssoSession == "my-sso")
    }

    @Test("Throws for a profile that is not present")
    func profileNotFound() {
        #expect(throws: AWSSSOError.profileNotFound("missing")) {
            _ = try AWSSSO.parseProfileSettings(configContent: config, profileName: "missing")
        }
    }

    @Test("Throws when the sso-session is missing required fields")
    func sessionMissingFields() {
        let broken = """
        [profile dev]
        sso_session = my-sso
        sso_account_id = 111122223333
        sso_role_name = Developer

        [sso-session my-sso]
        sso_start_url = https://example.awsapps.com/start
        """
        #expect(throws: AWSSSOError.sessionMissingFields(session: "my-sso")) {
            _ = try AWSSSO.parseProfileSettings(configContent: broken, profileName: "dev")
        }
    }
}

@Suite("AWS IAM connection fields in the plugin metadata registry")
@MainActor
struct RegistryAWSIAMFieldsTests {
    private func fieldIds(forTypeId typeId: String) -> [String] {
        PluginMetadataRegistry.shared.snapshot(forTypeId: typeId)?
            .connection.additionalConnectionFields.map(\.id) ?? []
    }

    @Test("MySQL, MariaDB, and PostgreSQL expose the AWS IAM auth fields")
    func iamFieldsPresent() {
        for typeId in ["MySQL", "MariaDB", "PostgreSQL"] {
            let ids = fieldIds(forTypeId: typeId)
            #expect(ids.contains("awsAuth"), "\(typeId) is missing the awsAuth field")
            #expect(ids.contains("awsRegion"), "\(typeId) is missing awsRegion")
            #expect(ids.contains("awsAccessKeyId"), "\(typeId) is missing awsAccessKeyId")
            #expect(ids.contains("awsSecretAccessKey"), "\(typeId) is missing awsSecretAccessKey")
            #expect(ids.contains("awsProfileName"), "\(typeId) is missing awsProfileName")
        }
    }

    @Test("The secret access key field is Keychain-backed (secure)")
    func secretFieldIsSecure() {
        let field = PluginMetadataRegistry.shared.snapshot(forTypeId: "MySQL")?
            .connection.additionalConnectionFields.first { $0.id == "awsSecretAccessKey" }
        #expect(field?.isSecure == true)
    }

    @Test("Redshift and CockroachDB do not offer AWS IAM auth")
    func excludedTypesHaveNoIAM() {
        #expect(!fieldIds(forTypeId: "Redshift").contains("awsAuth"))
        #expect(!fieldIds(forTypeId: "CockroachDB").contains("awsAuth"))
    }
}
