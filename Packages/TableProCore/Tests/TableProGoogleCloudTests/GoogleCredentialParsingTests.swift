import Foundation
@testable import TableProGoogleCloud
import Testing

@Suite("Service account key field parsing")
struct GoogleServiceAccountKeyParsingTests {
    private static let minimalJSON =
        #"{"type":"service_account","client_email":"a@proj.iam.gserviceaccount.com","private_key":"PEM","project_id":"proj"}"#

    private static func noFile(_ path: String) -> Data? {
        nil
    }

    @Test("Inline JSON is parsed with the default token URI")
    func inlineJSON() throws {
        let key = try GoogleServiceAccountKey.parse(fieldValue: Self.minimalJSON, readFile: Self.noFile)
        #expect(key.clientEmail == "a@proj.iam.gserviceaccount.com")
        #expect(key.privateKeyPEM == "PEM")
        #expect(key.projectId == "proj")
        #expect(key.tokenURI == GoogleOAuthClient.tokenEndpoint)
    }

    @Test("A leading byte order mark and surrounding whitespace are ignored")
    func byteOrderMark() throws {
        let value = "  \n\u{FEFF}" + Self.minimalJSON + "\n  "
        let key = try GoogleServiceAccountKey.parse(fieldValue: value, readFile: Self.noFile)
        #expect(key.clientEmail == "a@proj.iam.gserviceaccount.com")
    }

    @Test("A byte order mark inside a key file is ignored")
    func byteOrderMarkInFile() throws {
        let contents = Data([0xEF, 0xBB, 0xBF]) + Data(Self.minimalJSON.utf8)
        let key = try GoogleServiceAccountKey.parse(json: contents)
        #expect(key.projectId == "proj")
    }

    @Test("A pasted PEM key is recognised and rejected")
    func pastedPEM() {
        #expect(throws: GoogleAuthError.credentialIsPEM) {
            _ = try GoogleServiceAccountKey.parse(
                fieldValue: "-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----",
                readFile: Self.noFile
            )
        }
    }

    @Test("A path is read through readFile with the tilde expanded")
    func pathIsRead() throws {
        let requested = LockedBox<[String]>([])
        let key = try GoogleServiceAccountKey.parse(fieldValue: "~/keys/sa.json") { path in
            requested.mutate { $0.append(path) }
            return Data(Self.minimalJSON.utf8)
        }
        #expect(key.clientEmail == "a@proj.iam.gserviceaccount.com")
        let expected = (NSString(string: "~/keys/sa.json")).expandingTildeInPath
        #expect(requested.value == [expected])
        #expect(!expected.hasPrefix("~"))
    }

    @Test("An unreadable path throws credentialFileUnreadable")
    func unreadablePath() {
        #expect(throws: GoogleAuthError.credentialFileUnreadable) {
            _ = try GoogleServiceAccountKey.parse(fieldValue: "/nope/sa.json", readFile: Self.noFile)
        }
        #expect(throws: GoogleAuthError.credentialFileUnreadable) {
            _ = try GoogleServiceAccountKey.parse(fieldValue: "   ", readFile: Self.noFile)
        }
    }

    @Test("A key file holding PEM text is reported as PEM")
    func fileWithPEM() {
        #expect(throws: GoogleAuthError.credentialIsPEM) {
            _ = try GoogleServiceAccountKey.parse(fieldValue: "/tmp/key.pem") { _ in
                Data("-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----\n".utf8)
            }
        }
    }

    @Test("Text that is neither JSON nor a key throws credentialNotJSON")
    func notJSON() {
        #expect(throws: GoogleAuthError.credentialNotJSON) {
            _ = try GoogleServiceAccountKey.parse(json: Data("not json".utf8))
        }
        #expect(throws: GoogleAuthError.credentialNotJSON) {
            _ = try GoogleServiceAccountKey.parse(json: Data("[1,2]".utf8))
        }
        #expect(throws: GoogleAuthError.credentialNotJSON) {
            _ = try GoogleServiceAccountKey.parse(fieldValue: "{broken", readFile: Self.noFile)
        }
    }

    @Test("Missing fields name the JSON key only")
    func missingFields() {
        #expect(throws: GoogleAuthError.credentialMissingField("client_email")) {
            _ = try GoogleServiceAccountKey.parse(json: Data(#"{"private_key":"PEM"}"#.utf8))
        }
        #expect(throws: GoogleAuthError.credentialMissingField("private_key")) {
            _ = try GoogleServiceAccountKey.parse(json: Data(#"{"client_email":"a@b","private_key":""}"#.utf8))
        }
        #expect(throws: GoogleAuthError.credentialMissingField("client_email")) {
            _ = try GoogleServiceAccountKey.parse(json: Data(#"{"client_email":42,"private_key":"PEM"}"#.utf8))
        }
    }

    @Test("A credential of another type is refused")
    func wrongType() {
        #expect(throws: GoogleAuthError.unsupportedCredentialType("authorized_user")) {
            _ = try GoogleServiceAccountKey.parse(
                json: Data(#"{"type":"authorized_user","client_email":"a@b","private_key":"PEM"}"#.utf8)
            )
        }
    }

    @Test("A token_uri outside googleapis.com is refused and reports the host only")
    func untrustedTokenURI() {
        let cases: [(String, String)] = [
            ("https://evil.example.com/token", "evil.example.com"),
            ("http://oauth2.googleapis.com/token", "oauth2.googleapis.com"),
            ("https://googleapis.com.evil.io/token", "googleapis.com.evil.io"),
            ("https://user:pass@oauth2.googleapis.com/token", "oauth2.googleapis.com")
        ]
        for (uri, host) in cases {
            let json = #"{"client_email":"a@b","private_key":"PEM","token_uri":"\#(uri)"}"#
            #expect(throws: GoogleAuthError.untrustedEndpoint(host)) {
                _ = try GoogleServiceAccountKey.parse(json: Data(json.utf8))
            }
        }
    }

    @Test("A legacy accounts.google.com token_uri is kept")
    func legacyTokenURI() throws {
        let json = #"{"client_email":"a@b","private_key":"PEM","token_uri":"https://accounts.google.com/o/oauth2/token"}"#
        let key = try GoogleServiceAccountKey.parse(json: Data(json.utf8))
        #expect(key.tokenURI.absoluteString == "https://accounts.google.com/o/oauth2/token")
    }

    @Test("A lookalike of accounts.google.com is refused as a token_uri")
    func lookalikeLegacyTokenURI() {
        let cases: [(String, String)] = [
            ("https://accounts.google.com.evil.io/o/oauth2/token", "accounts.google.com.evil.io"),
            ("http://accounts.google.com/o/oauth2/token", "accounts.google.com"),
            ("https://evilaccounts.google.com/token", "evilaccounts.google.com")
        ]
        for (uri, host) in cases {
            let json = #"{"client_email":"a@b","private_key":"PEM","token_uri":"\#(uri)"}"#
            #expect(throws: GoogleAuthError.untrustedEndpoint(host)) {
                _ = try GoogleServiceAccountKey.parse(json: Data(json.utf8))
            }
        }
    }

    @Test("The token endpoint policy trusts accounts.google.com without widening the API policy")
    func tokenEndpointPolicy() throws {
        let legacy = try #require(URL(string: "https://accounts.google.com/o/oauth2/token"))
        let current = try #require(URL(string: "https://oauth2.googleapis.com/token"))
        let lookalike = try #require(URL(string: "https://accounts.google.com.evil.io/o/oauth2/token"))
        #expect(GoogleEndpointPolicy.isTrustedTokenEndpoint(legacy))
        #expect(GoogleEndpointPolicy.isTrustedTokenEndpoint(current))
        #expect(!GoogleEndpointPolicy.isTrustedTokenEndpoint(lookalike))
        #expect(!GoogleEndpointPolicy.isTrustedGoogleAPI(legacy))
        #expect(GoogleEndpointPolicy.isTrustedGoogleAPI(current))
    }

    @Test("A trusted token_uri is kept")
    func trustedTokenURI() throws {
        let json = #"{"client_email":"a@b","private_key":"PEM","token_uri":"https://oauth2.googleapis.com/token"}"#
        let key = try GoogleServiceAccountKey.parse(json: Data(json.utf8))
        #expect(key.tokenURI.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(key.projectId == nil)
    }

    @Test("Descriptions never contain the private key")
    func redactedDescription() throws {
        let key = try GoogleServiceAccountKey.parse(json: Data(Self.minimalJSON.utf8))
        #expect(!String(describing: key).contains("PEM"))
        #expect(!String(reflecting: key).contains("PEM"))
    }
}

@Suite("Application default credentials")
struct GoogleApplicationDefaultCredentialsTests {
    private static let authorizedUser =
        #"{"type":"authorized_user","client_id":"cid","client_secret":"s3cr3t-value","refresh_token":"rt-value","quota_project_id":"quota"}"#

    private static let serviceAccount =
        #"{"type":"service_account","client_email":"sa@p.iam.gserviceaccount.com","private_key":"PEM","project_id":"sa-project"}"#

    private static let impersonated = """
    {"type":"impersonated_service_account",\
    "service_account_impersonation_url":"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/t@p.iam.gserviceaccount.com:generateAccessToken",\
    "source_credentials":\(authorizedUser),"quota_project_id":"imp-quota"}
    """

    @Test("authorized_user is parsed")
    func authorizedUserParsed() throws {
        let credentials = try GoogleApplicationDefaultCredentials.parse(json: Data(Self.authorizedUser.utf8))
        #expect(
            credentials == .authorizedUser(
                clientId: "cid",
                clientSecret: "s3cr3t-value",
                refreshToken: "rt-value",
                quotaProjectId: "quota"
            )
        )
        #expect(credentials.projectHint == "quota")
    }

    @Test("service_account is parsed")
    func serviceAccountParsed() throws {
        let credentials = try GoogleApplicationDefaultCredentials.parse(json: Data(Self.serviceAccount.utf8))
        guard case .serviceAccount(let key) = credentials else {
            Issue.record("Expected a service account")
            return
        }
        #expect(key.clientEmail == "sa@p.iam.gserviceaccount.com")
        #expect(credentials.projectHint == "sa-project")
    }

    @Test("impersonated_service_account is parsed with its source")
    func impersonatedParsed() throws {
        let credentials = try GoogleApplicationDefaultCredentials.parse(json: Data(Self.impersonated.utf8))
        guard case .impersonatedServiceAccount(let url, let source, let quota, let delegates) = credentials else {
            Issue.record("Expected impersonated credentials")
            return
        }
        #expect(url.host == "iamcredentials.googleapis.com")
        #expect(
            source == .authorizedUser(
                clientId: "cid",
                clientSecret: "s3cr3t-value",
                refreshToken: "rt-value",
                quotaProjectId: "quota"
            )
        )
        #expect(quota == "imp-quota")
        #expect(delegates.isEmpty)
        #expect(credentials.projectHint == "imp-quota")
    }

    @Test("impersonated_service_account keeps its delegates chain")
    func impersonatedDelegatesParsed() throws {
        let json = """
        {"type":"impersonated_service_account",\
        "service_account_impersonation_url":"https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/t@p.iam.gserviceaccount.com:generateAccessToken",\
        "delegates":["projects/-/serviceAccounts/d1@p.iam.gserviceaccount.com"," ",7],\
        "source_credentials":\(Self.authorizedUser)}
        """
        let credentials = try GoogleApplicationDefaultCredentials.parse(json: Data(json.utf8))
        guard case .impersonatedServiceAccount(_, _, _, let delegates) = credentials else {
            Issue.record("Expected impersonated credentials")
            return
        }
        #expect(delegates == ["projects/-/serviceAccounts/d1@p.iam.gserviceaccount.com"])
    }

    @Test("external_account and unknown types are refused")
    func unsupportedTypes() {
        for type in ["external_account", "external_account_authorized_user", "gdch_service_account"] {
            #expect(throws: GoogleAuthError.unsupportedCredentialType(type)) {
                _ = try GoogleApplicationDefaultCredentials.parse(json: Data(#"{"type":"\#(type)"}"#.utf8))
            }
        }
    }

    @Test("A missing type is reported as a missing field")
    func missingType() {
        #expect(throws: GoogleAuthError.credentialMissingField("type")) {
            _ = try GoogleApplicationDefaultCredentials.parse(json: Data(#"{"client_id":"x"}"#.utf8))
        }
    }

    @Test("authorized_user without a refresh token names the field")
    func authorizedUserMissingField() {
        #expect(throws: GoogleAuthError.credentialMissingField("refresh_token")) {
            _ = try GoogleApplicationDefaultCredentials.parse(
                json: Data(#"{"type":"authorized_user","client_id":"c","client_secret":"s"}"#.utf8)
            )
        }
    }

    @Test("An impersonation URL outside googleapis.com is refused")
    func untrustedImpersonationURL() {
        let json = """
        {"type":"impersonated_service_account",\
        "service_account_impersonation_url":"https://attacker.example/generateAccessToken",\
        "source_credentials":\(Self.authorizedUser)}
        """
        #expect(throws: GoogleAuthError.untrustedEndpoint("attacker.example")) {
            _ = try GoogleApplicationDefaultCredentials.parse(json: Data(json.utf8))
        }
    }

    @Test("An impersonated source of an unsupported type is refused")
    func unsupportedImpersonationSource() {
        let json = """
        {"type":"impersonated_service_account",\
        "service_account_impersonation_url":"https://iamcredentials.googleapis.com/v1/x:generateAccessToken",\
        "source_credentials":{"type":"external_account"}}
        """
        #expect(throws: GoogleAuthError.unsupportedCredentialType("external_account")) {
            _ = try GoogleApplicationDefaultCredentials.parse(json: Data(json.utf8))
        }
    }

    @Test("An impersonated credential without a source names the field")
    func missingImpersonationSource() {
        let json = """
        {"type":"impersonated_service_account",\
        "service_account_impersonation_url":"https://iamcredentials.googleapis.com/v1/x:generateAccessToken"}
        """
        #expect(throws: GoogleAuthError.credentialMissingField("source_credentials")) {
            _ = try GoogleApplicationDefaultCredentials.parse(json: Data(json.utf8))
        }
    }

    @Test("An explicit path wins over the environment variable")
    func explicitPath() throws {
        let requested = LockedBox<[String]>([])
        _ = try GoogleApplicationDefaultCredentials.load(
            path: "/explicit/adc.json",
            readFile: { path in
                requested.mutate { $0.append(path) }
                return Data(Self.authorizedUser.utf8)
            },
            environment: ["GOOGLE_APPLICATION_CREDENTIALS": "/env/adc.json"]
        )
        #expect(requested.value == ["/explicit/adc.json"])
    }

    @Test("GOOGLE_APPLICATION_CREDENTIALS is used when no path is given")
    func environmentPath() throws {
        let requested = LockedBox<[String]>([])
        let credentials = try GoogleApplicationDefaultCredentials.load(
            path: "  ",
            readFile: { path in
                requested.mutate { $0.append(path) }
                return Data(Self.serviceAccount.utf8)
            },
            environment: ["GOOGLE_APPLICATION_CREDENTIALS": "/env/adc.json"]
        )
        #expect(requested.value == ["/env/adc.json"])
        #expect(credentials.projectHint == "sa-project")
    }

    @Test("The gcloud default path is used last")
    func defaultPath() throws {
        let requested = LockedBox<[String]>([])
        _ = try GoogleApplicationDefaultCredentials.load(
            path: nil,
            readFile: { path in
                requested.mutate { $0.append(path) }
                return Data(Self.authorizedUser.utf8)
            },
            environment: [:]
        )
        #expect(requested.value == [GoogleApplicationDefaultCredentials.defaultPath])
        #expect(GoogleApplicationDefaultCredentials.defaultPath.hasSuffix("/.config/gcloud/application_default_credentials.json"))
        #expect(!GoogleApplicationDefaultCredentials.defaultPath.hasPrefix("~"))
    }

    @Test("A missing default file and an unreadable configured file are told apart")
    func missingFiles() {
        #expect(throws: GoogleAuthError.applicationDefaultCredentialsNotFound) {
            _ = try GoogleApplicationDefaultCredentials.load(path: nil, readFile: { _ in nil }, environment: [:])
        }
        #expect(throws: GoogleAuthError.credentialFileUnreadable) {
            _ = try GoogleApplicationDefaultCredentials.load(
                path: nil,
                readFile: { _ in nil },
                environment: ["GOOGLE_APPLICATION_CREDENTIALS": "/env/adc.json"]
            )
        }
    }

    @Test("Descriptions never contain secrets")
    func redactedDescription() throws {
        let credentials = try GoogleApplicationDefaultCredentials.parse(json: Data(Self.impersonated.utf8))
        let text = String(describing: credentials)
        #expect(!text.contains("s3cr3t-value"))
        #expect(!text.contains("rt-value"))
        #expect(!String(reflecting: credentials).contains("rt-value"))
    }
}
