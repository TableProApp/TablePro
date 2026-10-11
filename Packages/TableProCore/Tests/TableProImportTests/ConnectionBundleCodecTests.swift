import Foundation
@testable import TableProImport
import Testing

@Suite("A connection file is read and written in one place")
struct ConnectionBundleCodecTests {
    private static let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let passphrase = "correct horse battery"

    @Test("A plain round trip keeps every field")
    func plainRoundTripKeepsEveryField() throws {
        let bundle = try Self.fullBundle()

        let decoded = try ConnectionBundleCodec.decode(ConnectionBundleCodec.encode(bundle))

        #expect(decoded == bundle)
    }

    @Test("Connection settings and link keys share one flat object")
    func connectionKeysAreFlat() throws {
        let object = try Self.jsonObject(ConnectionBundleCodec.encode(Self.fullBundle()))
        let connections = try #require(object["connections"] as? [[String: Any]])
        let first = try #require(connections.first)

        #expect(first["ref"] as? String == "c1")
        #expect(first["name"] as? String == "Orders")
        #expect(first["host"] as? String == "db.example.com")
        #expect(first["groupRef"] as? String == "g2")
        #expect(first["tagNames"] as? [String] == ["prod"])
        #expect(first["credentialProfileRef"] as? String == "p1")
        #expect(first["settings"] == nil)
    }

    @Test("The header and the connections array are always written; empty sections are not")
    func headerIsAlwaysWritten() throws {
        let bundle = try ConnectionBundle(exportedAt: Self.exportedAt, appVersion: "0.70.0", connections: [])

        let object = try Self.jsonObject(ConnectionBundleCodec.encode(bundle))

        #expect(object["formatVersion"] as? Int == 2)
        #expect(object["exportedAt"] as? String == "2023-11-14T22:13:20Z")
        #expect(object["appVersion"] as? String == "0.70.0")
        #expect((object["connections"] as? [Any])?.isEmpty == true)
        #expect(Set(object.keys) == ["formatVersion", "exportedAt", "appVersion", "connections"])
    }

    @Test("Credentials are a map keyed by connection ref")
    func credentialsAreKeyedByRef() async throws {
        let sealed = try await ConnectionBundleCodec.encode(Self.bundleWithCredentials(), passphrase: Self.passphrase)
        let json = try await ConnectionExportCrypto.decrypt(data: sealed, passphrase: Self.passphrase)

        let object = try Self.jsonObject(json)
        let credentials = try #require(object["credentials"] as? [String: [String: Any]])

        #expect(Set(credentials.keys) == ["c1"])
        #expect(credentials["c1"]?["password"] as? String == "hunter2")
    }

    @Test("A plain file never carries credentials into the app")
    func plainDecodeDropsCredentials() throws {
        let json = Data("""
        {"formatVersion":2,"exportedAt":"2023-11-14T22:13:20Z","appVersion":"0.70.0",
         "connections":[{"ref":"c1","name":"Orders","host":"h","port":5432,"database":"d","username":"u","type":"PostgreSQL"}],
         "credentials":{"c1":{"password":"planted"}}}
        """.utf8)

        let bundle = try ConnectionBundleCodec.decode(json)

        #expect(bundle.credentials.isEmpty)
        #expect(bundle.connections.count == 1)
    }

    @Test("Writing credentials to a plain file is refused")
    func plainEncodeRefusesCredentials() throws {
        let bundle = try Self.bundleWithCredentials()

        #expect(throws: ConnectionBundleError.credentialsRequireEncryption) {
            _ = try ConnectionBundleCodec.encode(bundle)
        }
    }

    @Test("An empty passphrase writes plain JSON and still refuses credentials")
    func emptyPassphraseIsPlain() async throws {
        let plain = try await ConnectionBundleCodec.encode(Self.fullBundle(), passphrase: "")
        #expect(!ConnectionBundleCodec.isEncrypted(plain))

        let withCredentials = try Self.bundleWithCredentials()
        await #expect(throws: ConnectionBundleError.credentialsRequireEncryption) {
            _ = try await ConnectionBundleCodec.encode(withCredentials, passphrase: "")
        }
    }

    @Test("An encrypted round trip keeps credentials")
    func encryptedRoundTripKeepsCredentials() async throws {
        let bundle = try Self.bundleWithCredentials()

        let sealed = try await ConnectionBundleCodec.encode(bundle, passphrase: Self.passphrase)
        let decoded = try await ConnectionBundleCodec.decode(sealed, passphrase: Self.passphrase)

        #expect(ConnectionBundleCodec.isEncrypted(sealed))
        #expect(decoded == bundle)
        #expect(decoded.credentials["c1"]?.password == "hunter2")
    }

    @Test("Reading an encrypted file without a passphrase asks for one")
    func encryptedFileNeedsPassphrase() async throws {
        let sealed = try await ConnectionBundleCodec.encode(Self.fullBundle(), passphrase: Self.passphrase)

        #expect(throws: ConnectionBundleError.requiresPassphrase) {
            _ = try ConnectionBundleCodec.decode(sealed)
        }
    }

    @Test("A wrong passphrase reports a decryption failure")
    func wrongPassphraseFails() async throws {
        let sealed = try await ConnectionBundleCodec.encode(Self.fullBundle(), passphrase: Self.passphrase)
        let expected = ConnectionBundleError.decryptionFailed(
            ConnectionExportCryptoError.invalidPassphrase.localizedDescription
        )

        await #expect(throws: expected) {
            _ = try await ConnectionBundleCodec.decode(sealed, passphrase: "wrong")
        }
    }

    @Test("A newer format is unsupported whatever its shape")
    func newerFormatIsUnsupported() {
        let json = Data(#"{"formatVersion":3,"bundle":{"anything":[1,2,3]}}"#.utf8)

        #expect(throws: ConnectionBundleError.unsupportedVersion(3)) {
            _ = try ConnectionBundleCodec.decode(json)
        }
    }

    @Test("A file without a usable format version is not a TablePro export")
    func missingVersionIsInvalidFormat() {
        let samples = [
            #"{"connections":[]}"#,
            #"{"formatVersion":"2","connections":[]}"#,
            #"{"formatVersion":0,"connections":[]}"#,
            "[1,2,3]",
            "not json"
        ]
        for sample in samples {
            #expect(throws: ConnectionBundleError.invalidFormat, "\(sample)") {
                _ = try ConnectionBundleCodec.decode(Data(sample.utf8))
            }
        }
    }

    @Test("A v2 file missing its header fails to parse")
    func missingHeaderFailsToParse() {
        let json = Data(#"{"formatVersion":2,"connections":[]}"#.utf8)

        let error = #expect(throws: ConnectionBundleError.self) {
            _ = try ConnectionBundleCodec.decode(json)
        }

        guard case .decodingFailed? = error else {
            Issue.record("Expected decodingFailed, got \(String(describing: error))")
            return
        }
    }

    @Test("A broken reference in a v2 file names the ref")
    func brokenReferenceIsInvalidBundle() {
        let json = Data("""
        {"formatVersion":2,"exportedAt":"2023-11-14T22:13:20Z","appVersion":"0.70.0",
         "connections":[{"ref":"c1","name":"Orders","host":"h","port":5432,"database":"d","username":"u",
                         "type":"PostgreSQL","groupRef":"g9"}]}
        """.utf8)
        let expected = ConnectionBundleError.invalidBundle(BundleViolation.unresolvedRef("g9", referrer: "c1").message)

        #expect(throws: expected) {
            _ = try ConnectionBundleCodec.decode(json)
        }
    }

    @Test("Decoding strips blocked additional fields and keeps valid timeouts")
    func decodeStripsBlockedFields() throws {
        let settings = Self.settings(
            connectTimeoutSeconds: 12,
            queryTimeoutSeconds: 0,
            additionalFields: ["schema": "public", "preConnectScript": "rm -rf /", "awsProfile": "admin"]
        )
        let data = try ConnectionBundleCodec.encode(Self.bundle(settings: [settings]))

        let imported = try #require(ConnectionBundleCodec.decode(data).connections.first?.settings)

        #expect(imported.additionalFields == ["schema": "public"])
        #expect(imported.connectTimeoutSeconds == 12)
        #expect(imported.queryTimeoutSeconds == 0)
    }

    @Test("An older file without timeout fields decodes them as nil")
    func olderFileWithoutTimeouts() throws {
        let json = Data("""
        {"formatVersion":1,"exportedAt":"1970-01-01T00:00:00Z","appVersion":"0.1",
         "connections":[{"name":"Legacy","host":"localhost","port":3306,"database":"","username":"","type":"MySQL"}]}
        """.utf8)

        let connection = try #require(ConnectionBundleCodec.decode(json).connections.first?.settings)

        #expect(connection.connectTimeoutSeconds == nil)
        #expect(connection.queryTimeoutSeconds == nil)
    }

    @Test("An invalid explicit timeout is dropped, not replaced by a legacy field")
    func invalidExplicitTimeoutsAreDropped() throws {
        let settings = Self.settings(
            connectTimeoutSeconds: 601,
            queryTimeoutSeconds: -1,
            additionalFields: ["connectTimeoutSeconds": "15", "queryTimeoutSeconds": "30", "schema": "public"]
        )
        let data = try ConnectionBundleCodec.encode(Self.bundle(settings: [settings]))

        let imported = try #require(ConnectionBundleCodec.decode(data).connections.first?.settings)

        #expect(imported.connectTimeoutSeconds == nil)
        #expect(imported.queryTimeoutSeconds == nil)
        #expect(imported.additionalFields == ["schema": "public"])
    }

    @Test("A legacy timeout field is used when no explicit timeout is set")
    func legacyTimeoutFieldsAreRead() throws {
        let settings = Self.settings(additionalFields: ["connectTimeoutSeconds": "15", "queryTimeoutSeconds": "30"])
        let data = try ConnectionBundleCodec.encode(Self.bundle(settings: [settings]))

        let imported = try #require(ConnectionBundleCodec.decode(data).connections.first?.settings)

        #expect(imported.connectTimeoutSeconds == 15)
        #expect(imported.queryTimeoutSeconds == 30)
        #expect(imported.additionalFields == nil)
    }

    @Test("The largest safe query timeout is accepted and the next second is not")
    func maximumSafeQueryTimeout() throws {
        let maximum = Int(Int32.max) / 1_000
        let data = try ConnectionBundleCodec.encode(Self.bundle(settings: [
            Self.settings(queryTimeoutSeconds: maximum),
            Self.settings(name: "Second", queryTimeoutSeconds: maximum + 1)
        ]))

        let decoded = try ConnectionBundleCodec.decode(data)

        #expect(decoded.connections[0].settings.queryTimeoutSeconds == maximum)
        #expect(decoded.connections[1].settings.queryTimeoutSeconds == nil)
    }

    @Test("Copies of a connection keep its timeouts")
    func copiesKeepTimeouts() {
        let settings = Self.settings(
            connectTimeoutSeconds: 12,
            queryTimeoutSeconds: 0,
            additionalFields: ["preConnectScript": "blocked", "schema": "public"]
        )

        let copies = [settings.withoutStartupCommands(), settings.withoutTunnelCommand(), settings.sanitizedForImport()]

        #expect(copies.allSatisfy { $0.connectTimeoutSeconds == 12 })
        #expect(copies.allSatisfy { $0.queryTimeoutSeconds == 0 })
    }

    @Test("iPhone SSL spellings decode to the canonical mode")
    func iosSSLSpellingsDecodeCanonical() throws {
        let json = Data("""
        {"formatVersion":2,"exportedAt":"2023-11-14T22:13:20Z","appVersion":"1.0",
         "connections":[
           {"ref":"a","name":"A","host":"a","port":5432,"database":"d","username":"u","type":"PostgreSQL","sslConfig":{"mode":"require"}},
           {"ref":"b","name":"B","host":"b","port":5432,"database":"d","username":"u","type":"PostgreSQL","sslConfig":{"mode":"verifyFull"}},
           {"ref":"c","name":"C","host":"c","port":5432,"database":"d","username":"u","type":"PostgreSQL","sslConfig":{"mode":"allow"}}
         ]}
        """.utf8)

        let modes = try ConnectionBundleCodec.decode(json).connections.map { $0.settings.sslConfig?.mode }

        #expect(modes == ["Required", "Verify Identity", "allow"])
    }

    @Test("Home-relative paths round trip")
    func pathPortabilityRoundTrips() {
        let original = NSHomeDirectory() + "/.ssh/id_rsa"
        let contracted = PathPortability.contractHome(original)

        #expect(contracted.hasPrefix("~/"))
        #expect(PathPortability.expandHome(contracted) == original)
    }

    private static func settings(
        name: String = "Local",
        connectTimeoutSeconds: Int? = nil,
        queryTimeoutSeconds: Int? = nil,
        additionalFields: [String: String]? = nil
    ) -> ExportableConnection {
        ExportableConnection(
            name: name, host: "127.0.0.1", port: 3_306, database: "test", username: "root", type: "MySQL",
            connectTimeoutSeconds: connectTimeoutSeconds,
            queryTimeoutSeconds: queryTimeoutSeconds,
            additionalFields: additionalFields
        )
    }

    private static func bundle(settings: [ExportableConnection]) throws -> ConnectionBundle {
        try ConnectionBundle(
            exportedAt: exportedAt,
            appVersion: "0.70.0",
            connections: settings.enumerated().map { BundleConnection(ref: BundleRef("c\($0.offset + 1)"), settings: $0.element) }
        )
    }

    private static func bundleWithCredentials() throws -> ConnectionBundle {
        try ConnectionBundle(
            exportedAt: exportedAt,
            appVersion: "0.70.0",
            connections: [BundleConnection(ref: "c1", settings: settings())],
            credentials: ["c1": ExportableCredentials(
                password: "hunter2",
                sshPassword: nil,
                keyPassphrase: "phrase",
                sslClientKeyPassphrase: nil,
                totpSecret: nil,
                pluginSecureFields: ["token": "secret"]
            )]
        )
    }

    static func fullSettings() -> ExportableConnection {
        ExportableConnection(
            name: "Orders",
            host: "db.example.com",
            port: 5_432,
            database: "orders",
            username: "app",
            type: "PostgreSQL",
            sshConfig: ExportableSSHConfig(
                enabled: true, host: "bastion", port: 2_222, username: "deploy",
                authMethod: "privateKey", privateKeyPath: "~/.ssh/id_ed25519", agentSocketPath: "",
                jumpHosts: [ExportableJumpHost(host: "jump", port: 22, username: "hop", authMethod: "sshAgent", privateKeyPath: "")],
                totpMode: "autoGenerate", totpAlgorithm: "sha256", totpDigits: 8, totpPeriod: 60,
                remoteFilePath: "/srv/app.db", remoteFileAccess: "onServer"
            ),
            sslConfig: ExportableSSLConfig(mode: "Verify CA", caCertificatePath: "~/ca.pem"),
            color: "Blue",
            sshProfileId: "8C0A2F0E-1D7B-4C35-9E52-5B0D9F6A1C11",
            safeModeLevel: "confirm",
            aiPolicy: "never",
            connectTimeoutSeconds: 12,
            queryTimeoutSeconds: 30,
            additionalFields: ["schema": "public"],
            redisDatabase: 2,
            startupCommands: "SET search_path TO app",
            localOnly: true,
            tunnelCommand: ExportableTunnelCommand(
                method: "kubectl", command: nil, executablePath: "/usr/local/bin/kubectl",
                kubernetesNamespace: "db", kubernetesResource: "svc/postgres", kubernetesContext: "prod",
                awsTarget: nil, awsProfile: nil, awsRegion: nil
            )
        )
    }

    static func fullBundle() throws -> ConnectionBundle {
        try ConnectionBundle(
            exportedAt: exportedAt,
            appVersion: "0.70.0",
            connections: [
                BundleConnection(ref: "c1", settings: fullSettings(), groupRef: "g2", tagNames: ["prod"], credentialProfileRef: "p1"),
                BundleConnection(ref: "c2", settings: settings(name: "Cache"))
            ],
            groups: [
                BundleGroup(ref: "g1", name: "Client A", color: "Blue"),
                BundleGroup(ref: "g2", name: "Production", parentRef: "g1")
            ],
            tags: [BundleTag(name: "prod", color: "Red")],
            credentialProfiles: [
                BundleCredentialProfile(ref: "p1", name: "reader", username: "ro", passwordMode: .pgpass, secureFieldIds: ["token"])
            ],
            queryFolders: [
                BundleQueryFolder(ref: "f1", name: "Reports", connectionRef: "c1"),
                BundleQueryFolder(ref: "f2", name: "Daily", parentRef: "f1", connectionRef: "c1"),
                BundleQueryFolder(ref: "f3", name: "Shared")
            ],
            savedQueries: [
                BundleSavedQuery(ref: "q1", name: "Daily active users", sql: "SELECT 1", keyword: "dau", folderRef: "f2", connectionRef: "c1"),
                BundleSavedQuery(ref: "q2", name: "Locks", sql: "SELECT * FROM pg_locks", folderRef: "f3"),
                BundleSavedQuery(ref: "q3", name: "", sql: "SELECT now()")
            ]
        )
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
