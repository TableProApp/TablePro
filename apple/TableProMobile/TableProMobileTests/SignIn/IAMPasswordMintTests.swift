import Foundation
import os
import TableProDatabase
import TableProGoogleCloud
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

private final class RecordedAccessTokens: Sendable {
    private let tokens = OSAllocatedUnfairLock<[String]>(initialState: [])

    func append(_ token: String) {
        tokens.withLock { $0.append(token) }
    }

    var all: [String] {
        tokens.withLock { $0 }
    }
}

struct IAMPasswordMintTests {
    private static let rdsHost = "mydb.abc123.us-east-1.rds.amazonaws.com"
    private static let startUrl = "https://example.awsapps.com/start"
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)
    private static let serviceAccountEmail = "reader@project.iam.gserviceaccount.com"
    private static let serviceAccountJSON = """
        {"type":"service_account","client_email":"reader@project.iam.gserviceaccount.com",\
        "private_key":"-----BEGIN PRIVATE KEY-----\\nMIIB\\n-----END PRIVATE KEY-----\\n","project_id":"project"}
        """
    private static let roleCredentials = AWSCredentials(
        accessKeyId: "ASIAROLE",
        secretAccessKey: "role-secret",
        sessionToken: "role-session"
    )

    private let store = EphemeralSecureStore()
    private let ssoTokens = AWSSSOTokenStore(items: EphemeralSecureStore())
    private let seenAccessTokens = RecordedAccessTokens()

    private var mint: IAMPasswordMint {
        let seen = seenAccessTokens
        return IAMPasswordMint(
            ssoTokens: ssoTokens,
            fetchRoleCredentials: { accessToken, _, _ in
                seen.append(accessToken)
                return Self.roleCredentials
            },
            fetchGoogleToken: { key in "google-token-for-\(key.clientEmail)" },
            now: { Self.now }
        )
    }

    private func makeConnection(
        type: DatabaseType = .postgresql,
        host: String = Self.rdsHost,
        method: IAMSignIn,
        sshEnabled: Bool = false,
        sslEnabled: Bool = true,
        fields: [String: String] = [:]
    ) -> DatabaseConnection {
        var additionalFields = fields
        additionalFields[IAMSignIn.Field.method] = method.pickerValue
        return DatabaseConnection(
            type: type,
            host: host,
            port: 5_432,
            username: "iam_user",
            additionalFields: additionalFields,
            sshEnabled: sshEnabled,
            sshConfiguration: sshEnabled ? SSHConfiguration(host: "bastion.example.com", username: "ec2-user") : nil,
            sslEnabled: sslEnabled
        )
    }

    private func accessKeyConnection(host: String = Self.rdsHost, sshEnabled: Bool, fields: [String: String] = [:]) throws -> DatabaseConnection {
        var accessKeyFields = fields
        accessKeyFields[IAMSignIn.Field.accessKeyId] = "AKIDEXAMPLE"
        let connection = makeConnection(host: host, method: .awsAccessKey, sshEnabled: sshEnabled, fields: accessKeyFields)
        try store.store("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", forKey: ConnectionSecretKind.awsSecretAccessKey.account(for: connection.id))
        return connection
    }

    private func signed(host: String, port: Int = 5_432, credentials: AWSCredentials) throws -> String {
        try AWSIAMTokenTarget.rds(
            configuredHost: host,
            configuredPort: port,
            preTunnelHost: nil,
            preTunnelPort: nil,
            defaultPort: port
        ).token(username: "iam_user", fields: [:], credentials: credentials, now: Self.now)
    }

    private var exampleKey: AWSCredentials {
        AWSCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", sessionToken: nil)
    }

    private func saveSSOSetup(for connection: DatabaseConnection, startUrl: String = Self.startUrl) throws {
        try DeviceIAMCredentials(
            ssoStartUrl: startUrl,
            ssoRegion: "us-east-1",
            ssoAccountId: "111122223333",
            ssoRoleName: "ReadOnly"
        ).save(for: connection.id, to: store)
    }

    private func saveSSOToken(expiresAt: Date) throws {
        try ssoTokens.save(
            AWSSSOTokenCacheEntry(accessToken: "sso-access-token", expiresAt: expiresAt, region: "us-east-1", startUrl: Self.startUrl),
            startUrl: Self.startUrl
        )
    }

    // MARK: - AWS

    @Test("Behind SSH, the token signs the RDS Endpoint override")
    func sshSignsTheOverride() async throws {
        let connection = try accessKeyConnection(
            host: "10.0.1.5",
            sshEnabled: true,
            fields: [IAMSignIn.Field.rdsEndpoint: "\(Self.rdsHost):5432"]
        )

        let token = try await mint.password(for: connection, method: .awsAccessKey, secureStore: store)
        let expected = try signed(host: Self.rdsHost, credentials: exampleKey)

        #expect(token == expected)
        #expect(token.hasPrefix("\(Self.rdsHost):5432/?Action=connect&DBUser=iam_user&"))
    }

    @Test("Behind SSH with no override, the token signs the saved host")
    func sshSignsTheSavedHost() async throws {
        let connection = try accessKeyConnection(sshEnabled: true)

        let token = try await mint.password(for: connection, method: .awsAccessKey, secureStore: store)
        let expected = try signed(host: Self.rdsHost, credentials: exampleKey)

        #expect(token == expected)
    }

    @Test("Without SSH, an override naming another host is refused, as on the Mac")
    func directConnectionRefusesAnotherOverride() async throws {
        let connection = try accessKeyConnection(
            host: "db.internal.example.com",
            sshEnabled: false,
            fields: [IAMSignIn.Field.rdsEndpoint: "\(Self.rdsHost):5432"]
        )

        await #expect(throws: AWSAuthError.rdsEndpointUnresolved(host: "db.internal.example.com")) {
            try await mint.password(for: connection, method: .awsAccessKey, secureStore: store)
        }
    }

    @Test("An access key connection without its secret on this device says so")
    func accessKeyMissing() async {
        let connection = makeConnection(method: .awsAccessKey, fields: [IAMSignIn.Field.accessKeyId: "AKIDEXAMPLE"])

        await #expect(throws: IAMSignInError.accessKeyMissing) {
            try await mint.password(for: connection, method: .awsAccessKey, secureStore: store)
        }
    }

    @Test("A synced session token is signed into the token")
    func sessionTokenIsSigned() async throws {
        let connection = try accessKeyConnection(sshEnabled: false)
        try store.store("session-token", forKey: ConnectionSecretKind.awsSessionToken.account(for: connection.id))

        let token = try await mint.password(for: connection, method: .awsAccessKey, secureStore: store)

        #expect(token.contains("X-Amz-Security-Token=session-token"))
    }

    @Test("A Profile connection without a key for this device names the profile")
    func profileNeedsDeviceKey() async {
        let connection = makeConnection(method: .awsProfile, fields: [IAMSignIn.Field.profileName: "analytics"])

        await #expect(throws: IAMSignInError.profileNeedsDeviceKey(profile: "analytics")) {
            try await mint.password(for: connection, method: .awsProfile, secureStore: store)
        }
    }

    @Test("A Profile connection signs with the key added for this device")
    func profileSignsWithDeviceKey() async throws {
        let connection = makeConnection(method: .awsProfile)
        try DeviceIAMCredentials(
            accessKeyId: " AKIDEXAMPLE\n",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
        ).save(for: connection.id, to: store)

        let token = try await mint.password(for: connection, method: .awsProfile, secureStore: store)
        let expected = try signed(host: Self.rdsHost, credentials: exampleKey)

        #expect(token == expected)
    }

    @Test("Two connections on one IAM Identity Center share one sign-in")
    func ssoTokenIsShared() async throws {
        let first = makeConnection(method: .awsSSO)
        let second = makeConnection(type: .mysql, method: .awsSSO)
        try saveSSOSetup(for: first)
        try saveSSOSetup(for: second, startUrl: Self.startUrl + "/")
        try saveSSOToken(expiresAt: Self.now.addingTimeInterval(3_600))

        let firstToken = try await mint.password(for: first, method: .awsSSO, secureStore: store)
        _ = try await mint.password(for: second, method: .awsSSO, secureStore: store)
        let expected = try signed(host: Self.rdsHost, credentials: Self.roleCredentials)

        #expect(seenAccessTokens.all == ["sso-access-token", "sso-access-token"])
        #expect(firstToken == expected)
    }

    @Test("IAM Identity Center that is not set up on this device says so")
    func ssoNotSetUp() async throws {
        let connection = makeConnection(method: .awsSSO)
        try saveSSOToken(expiresAt: Self.now.addingTimeInterval(3_600))

        await #expect(throws: IAMSignInError.ssoNotSetUp) {
            try await mint.password(for: connection, method: .awsSSO, secureStore: store)
        }
    }

    @Test("An expired IAM Identity Center token asks for a sign-in")
    func expiredSSOToken() async throws {
        let connection = makeConnection(method: .awsSSO)
        try saveSSOSetup(for: connection)
        try saveSSOToken(expiresAt: Self.now.addingTimeInterval(-60))

        await #expect(throws: IAMSignInError.ssoSignInRequired) {
            try await mint.password(for: connection, method: .awsSSO, secureStore: store)
        }
        #expect(seenAccessTokens.all.isEmpty)
    }

    @Test("A token the refresher renews signs in with the new one, read for the device's start URL")
    func ssoTokenRefreshed() async throws {
        let connection = makeConnection(method: .awsSSO)
        try saveSSOSetup(for: connection)
        try saveSSOToken(expiresAt: Self.now.addingTimeInterval(60))
        let seen = seenAccessTokens
        let refreshedFor = OSAllocatedUnfairLock<[String]>(initialState: [])
        let refreshing = IAMPasswordMint(
            ssoTokens: ssoTokens,
            fetchRoleCredentials: { accessToken, _, _ in
                seen.append(accessToken)
                return Self.roleCredentials
            },
            refreshSSOToken: { stored, startUrl, _ in
                refreshedFor.withLock { $0.append(startUrl) }
                return AWSSSOTokenCacheEntry(
                    accessToken: "refreshed-token",
                    expiresAt: Self.now.addingTimeInterval(8 * 3_600),
                    region: stored.region,
                    startUrl: stored.startUrl
                )
            },
            now: { Self.now }
        )

        _ = try await refreshing.password(for: connection, method: .awsSSO, secureStore: store)

        #expect(seenAccessTokens.all == ["refreshed-token"])
        #expect(refreshedFor.withLock { $0 } == [Self.startUrl])
    }

    @Test("An expired token the refresher cannot renew asks for a sign-in")
    func ssoTokenNotRenewed() async throws {
        let connection = makeConnection(method: .awsSSO)
        try saveSSOSetup(for: connection)
        try saveSSOToken(expiresAt: Self.now.addingTimeInterval(-60))
        let keeping = IAMPasswordMint(
            ssoTokens: ssoTokens,
            fetchRoleCredentials: { _, _, _ in Self.roleCredentials },
            refreshSSOToken: { stored, _, _ in stored },
            now: { Self.now }
        )

        await #expect(throws: IAMSignInError.ssoSignInRequired) {
            try await keeping.password(for: connection, method: .awsSSO, secureStore: store)
        }
    }

    @Test("A session the portal no longer accepts is cleared and asks for a sign-in")
    func revokedSSOSession() async throws {
        let connection = makeConnection(method: .awsSSO)
        try saveSSOSetup(for: connection)
        try saveSSOToken(expiresAt: Self.now.addingTimeInterval(3_600))
        let revoking = IAMPasswordMint(
            ssoTokens: ssoTokens,
            fetchRoleCredentials: { _, _, profile in throw AWSSSOError.sessionUnauthorized(profile: profile) },
            now: { Self.now }
        )

        await #expect(throws: IAMSignInError.ssoSignInRequired) {
            try await revoking.password(for: connection, method: .awsSSO, secureStore: store)
        }
        #expect(ssoTokens.token(startUrl: Self.startUrl) == nil)
    }

    @Test("Redis with SSL off keeps the Mac's requires-TLS error")
    func elastiCacheWithSSLOff() async throws {
        let connection = makeConnection(
            type: .redis,
            host: "my-cache.abc123.use1.cache.amazonaws.com",
            method: .awsAccessKey,
            sslEnabled: false,
            fields: [
                IAMSignIn.Field.accessKeyId: "AKIDEXAMPLE",
                IAMSignIn.Field.region: "us-east-1",
                IAMSignIn.Field.replicationGroupId: "my-cache"
            ]
        )
        try store.store("secret", forKey: ConnectionSecretKind.awsSecretAccessKey.account(for: connection.id))

        let error = await #expect(throws: AWSAuthError.self) {
            try await mint.password(for: connection, method: .awsAccessKey, secureStore: store)
        }
        guard case .missingConfiguration = error else {
            Issue.record("Expected the requires-TLS error, got \(String(describing: error))")
            return
        }
    }

    @Test("Redis with SSL on signs its cache name")
    func elastiCacheWithSSLOn() async throws {
        let connection = makeConnection(
            type: .redis,
            host: "my-cache.abc123.use1.cache.amazonaws.com",
            method: .awsAccessKey,
            fields: [
                IAMSignIn.Field.accessKeyId: "AKIDEXAMPLE",
                IAMSignIn.Field.region: "us-east-1",
                IAMSignIn.Field.replicationGroupId: "my-cache"
            ]
        )
        try store.store("secret", forKey: ConnectionSecretKind.awsSecretAccessKey.account(for: connection.id))

        let token = try await mint.password(for: connection, method: .awsAccessKey, secureStore: store)

        #expect(token.hasPrefix("my-cache/?Action=connect&User=iam_user&"))
    }

    // MARK: - Google Cloud

    @Test("A pasted key with a leading newline or byte order mark parses", arguments: ["\n", "\u{FEFF}", "\n\u{FEFF}", "\u{FEFF}\n  "])
    func paddedKeyParses(padding: String) throws {
        let key = try IAMPasswordMint.serviceAccountKey(padding + Self.serviceAccountJSON, whenMissing: .serviceAccountKeyMissing)

        #expect(key.clientEmail == Self.serviceAccountEmail)
    }

    @Test("A service account connection signs with the synced key")
    func serviceAccountSigns() async throws {
        let connection = makeConnection(method: .googleServiceAccount)
        try store.store("\n" + Self.serviceAccountJSON, forKey: ConnectionSecretKind.gcpServiceAccountKey.account(for: connection.id))

        let token = try await mint.password(for: connection, method: .googleServiceAccount, secureStore: store)

        #expect(token == "google-token-for-\(Self.serviceAccountEmail)")
    }

    @Test("A key that is a file path on the Mac asks for the JSON", arguments: ["/Users/me/keys/reader.json", "~/keys/reader.json"])
    func macPathIsAMacFile(path: String) async throws {
        let connection = makeConnection(method: .googleServiceAccount)
        try store.store(path, forKey: ConnectionSecretKind.gcpServiceAccountKey.account(for: connection.id))

        await #expect(throws: IAMSignInError.serviceAccountKeyIsMacFile) {
            try await mint.password(for: connection, method: .googleServiceAccount, secureStore: store)
        }
    }

    @Test("A service account connection with no key on this device says so", arguments: [nil, "", " \n\u{FEFF}"] as [String?])
    func serviceAccountKeyMissing(value: String?) {
        #expect(throws: IAMSignInError.serviceAccountKeyMissing) {
            try IAMPasswordMint.serviceAccountKey(value, whenMissing: .serviceAccountKeyMissing)
        }
    }

    @Test("A pasted PEM keeps its own message")
    func pastedPEM() {
        #expect(throws: GoogleAuthError.credentialIsPEM) {
            try IAMPasswordMint.serviceAccountKey("-----BEGIN PRIVATE KEY-----\nMIIB\n", whenMissing: .serviceAccountKeyMissing)
        }
    }

    @Test("Application Default without a key for this device says what the phone needs")
    func applicationDefaultNeedsDeviceKey() async {
        let connection = makeConnection(method: .googleApplicationDefault)

        await #expect(throws: IAMSignInError.applicationDefaultNeedsDeviceKey) {
            try await mint.password(for: connection, method: .googleApplicationDefault, secureStore: store)
        }
    }

    @Test("Application Default signs with the key added for this device")
    func applicationDefaultSignsWithDeviceKey() async throws {
        let connection = makeConnection(method: .googleApplicationDefault)
        try DeviceIAMCredentials(serviceAccountKey: Self.serviceAccountJSON).save(for: connection.id, to: store)

        let token = try await mint.password(for: connection, method: .googleApplicationDefault, secureStore: store)

        #expect(token == "google-token-for-\(Self.serviceAccountEmail)")
    }

    // MARK: - Device-only settings

    @Test("Device sign-in settings round trip, and clearing them deletes the item")
    func deviceCredentialsRoundTrip() throws {
        let id = UUID()
        let saved = DeviceIAMCredentials(serviceAccountKey: Self.serviceAccountJSON, ssoStartUrl: Self.startUrl)

        try saved.save(for: id, to: store)
        #expect(try DeviceIAMCredentials.load(for: id, from: store) == saved)

        try DeviceIAMCredentials().save(for: id, to: store)
        #expect(try store.retrieve(forKey: ConnectionSecretKind.deviceIAM.account(for: id)) == nil)
        #expect(try DeviceIAMCredentials.load(for: id, from: store).isEmpty)
    }

    // MARK: - Driver factory

    @Test("An IAM connection with SSL off is raised to Required in the driver only", arguments: [DatabaseType.mysql, .postgresql])
    func tlsRaisedForIAM(type: DatabaseType) throws {
        let connection = makeConnection(type: type, method: .awsAccessKey, sslEnabled: false)

        let ssl = try IOSDriverFactory().ssl(for: connection, serverName: nil)

        #expect(ssl.mode == .require)
        #expect(!connection.sslEnabled)
    }

    @Test("An IAM connection on the Mac's Preferred is raised to Required, keeping its certificates")
    func preferredRaisedForIAM() throws {
        var connection = makeConnection(type: .mysql, method: .awsAccessKey)
        connection.sslConfiguration = SSLConfiguration(mode: .require, isMacPreferred: true)

        let ssl = try IOSDriverFactory().ssl(for: connection, serverName: nil)

        #expect(ssl.mode == .require)
        #expect(!ssl.isPreferred)
        #expect(MySQLTLSPolicy(ssl) == .required)
    }

    @Test("A password connection keeps the Mac's Preferred")
    func preferredKeptWithoutIAM() throws {
        var connection = DatabaseConnection(type: .mysql, host: Self.rdsHost, sslEnabled: true)
        connection.sslConfiguration = SSLConfiguration(mode: .require, isMacPreferred: true)

        #expect(try IOSDriverFactory().ssl(for: connection, serverName: nil).isPreferred)
    }

    @Test("A verifying SSL mode is kept for an IAM connection")
    func verifyingModeKept() throws {
        var connection = makeConnection(method: .awsAccessKey)
        connection.sslConfiguration = SSLConfiguration(mode: .verifyFull)

        #expect(try IOSDriverFactory().ssl(for: connection, serverName: nil).mode == .verifyFull)
    }

    @Test("A password connection with SSL off stays off")
    func passwordConnectionKeepsSSLOff() throws {
        let connection = DatabaseConnection(type: .postgresql, host: Self.rdsHost, sslEnabled: false)

        #expect(try IOSDriverFactory().ssl(for: connection, serverName: nil).mode == .disable)
    }

    @Test("Behind a tunnel, the certificate is checked against the saved host")
    func serverNameIsThePreTunnelHost() throws {
        let connection = DatabaseConnection(type: .postgresql, host: "127.0.0.1", sslEnabled: true)

        let tunneled = try IOSDriverFactory().ssl(for: connection, serverName: Self.rdsHost)
        let direct = try IOSDriverFactory().ssl(for: connection, serverName: nil)

        #expect(tunneled.serverName == Self.rdsHost)
        #expect(direct.serverName == nil)
    }

    @Test("MySQL signs in with a token only for an IAM connection")
    func mySQLSignsInWithToken() throws {
        let iam = makeConnection(type: .mysql, method: .awsAccessKey, sslEnabled: false)
        let plain = DatabaseConnection(type: .mysql, host: Self.rdsHost)
        let factory = IOSDriverFactory()

        let iamDriver = try #require(try factory.createDriver(for: iam, password: "token", preTunnelHost: nil) as? MySQLDriver)
        let passwordDriver = try #require(try factory.createDriver(for: plain, password: "pw") as? MySQLDriver)

        #expect(iamDriver.signsInWithToken)
        #expect(iamDriver.ssl.mode == .require)
        #expect(!passwordDriver.signsInWithToken)
    }

    @Test("Redis checks its certificate against the saved host behind a tunnel")
    func redisGetsServerName() throws {
        let connection = DatabaseConnection(type: .redis, host: "127.0.0.1", port: 6_379, sslEnabled: true)

        let driver = try IOSDriverFactory().createDriver(for: connection, password: nil, preTunnelHost: "cache.example.com")
        let redis = try #require(driver as? RedisDriver)

        #expect(redis.ssl.serverName == "cache.example.com")
    }

    @Test("A password connection keeps its stored password")
    func passwordConnectionUsesStoredPassword() async throws {
        let connection = DatabaseConnection(type: .postgresql, host: Self.rdsHost)

        let password = try await IOSDriverFactory(mint: mint).resolvePassword(for: connection, stored: "pw", secureStore: store)

        #expect(password == "pw")
    }

    @Test("An engine without IAM keeps its stored password despite a synced awsAuth")
    func engineWithoutIAMUsesStoredPassword() async throws {
        let connection = DatabaseConnection(type: .redshift, host: Self.rdsHost, additionalFields: [IAMSignIn.Field.method: "accessKey"])

        let password = try await IOSDriverFactory(mint: mint).resolvePassword(for: connection, stored: "pw", secureStore: store)

        #expect(password == "pw")
    }

    @Test("An IAM connection signs a token instead of the stored password")
    func iamConnectionSignsAToken() async throws {
        let connection = try accessKeyConnection(sshEnabled: false)

        let password = try await IOSDriverFactory(mint: mint).resolvePassword(for: connection, stored: "stale", secureStore: store)
        let expected = try signed(host: Self.rdsHost, credentials: exampleKey)

        #expect(password == expected)
    }
}
