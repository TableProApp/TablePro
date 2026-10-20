import Foundation
import TableProImport
import Testing

/// The frozen copy of the format 1 reader references no live type, so editing a live type cannot make this pass
/// while an older build would fail to decode a new file instead of opening it or reporting its version.
@Suite("An older build opens a format 1 file and reports a format 2 file as needing a newer version")
struct ConnectionBundleOldBuildCompatibilityTests {
    @Test("A file without saved queries or nested groups opens in an older build, linked by name")
    func flatFileOpens() throws {
        let data = try ConnectionBundleCodec.encode(ConnectionBundleCodecTests.flatBundle().withoutCredentials())

        let envelope = try OldBuild.decode(data)

        #expect(envelope.formatVersion == 1)
        #expect(envelope.appVersion == "0.70.0")
        #expect(envelope.connections.map(\.name) == ["Orders", "Cache"])
        #expect(envelope.connections.map(\.groupName) == ["Production", "Production"])
        #expect(envelope.connections.first?.tagName == "prod")
        #expect(envelope.connections.first?.tagNames == ["prod", "team"])
        #expect(envelope.connections.map(\.credentialProfileName) == ["reader", "reader"])
        #expect(envelope.connections.first?.sshConfig?.jumpHosts?.first?.host == "jump")
        #expect(envelope.groups?.map(\.name) == ["Production"])
        #expect(envelope.groups?.first?.color == "Blue")
        #expect(envelope.tags?.map(\.name) == ["prod", "team"])
        #expect(envelope.credentialProfiles?.first?.passwordMode == "pgpass")
        #expect(envelope.credentialProfiles?.first?.secureFieldIds == ["token"])
    }

    @Test("An encrypted format 1 file opens in an older build with each password under its connection's position")
    func encryptedFlatFileOpens() async throws {
        let sealed = try await ConnectionBundleCodec.encode(ConnectionBundleCodecTests.flatBundle(), passphrase: "pw")

        let json = try await ConnectionExportCrypto.decrypt(data: sealed, passphrase: "pw")
        let envelope = try OldBuild.decode(json)

        #expect(envelope.formatVersion == 1)
        #expect(envelope.credentials?.keys.sorted() == ["1"])
        #expect(envelope.credentials?["1"]?.password == "hunter2")
        #expect(envelope.credentials?["1"]?.pluginSecureFields == ["token": "secret"])
    }

    @Test("A plain format 2 file decodes with the format 1 types and reads version 2")
    func plainFileDecodesAsVersionTwo() throws {
        let data = try ConnectionBundleCodec.encode(ConnectionBundleCodecTests.fullBundle())

        let envelope = try OldBuild.decodeWithoutGate(data)

        #expect(envelope.formatVersion == 2)
        #expect(envelope.appVersion == "0.70.0")
        #expect(envelope.connections.map(\.name) == ["Orders", "Cache"])
        #expect(envelope.groups?.map(\.name) == ["Client A", "Production"])
        #expect(envelope.tags?.map(\.name) == ["prod"])
        #expect(envelope.credentialProfiles?.first?.passwordMode == "pgpass")
    }

    @Test("Every nested shape a format 1 build reads is still in place")
    func nestedShapesStayReadable() throws {
        let data = try ConnectionBundleCodec.encode(ConnectionBundleCodecTests.fullBundle())

        let orders = try #require(OldBuild.decodeWithoutGate(data).connections.first)

        #expect(orders.port == 5_432)
        #expect(orders.tagNames == ["prod"])
        #expect(orders.sshConfig?.jumpHosts?.first?.host == "jump")
        #expect(orders.sshConfig?.remoteFileAccess == "onServer")
        #expect(orders.sslConfig?.mode == "Verify CA")
        #expect(orders.tunnelCommand?.kubernetesResource == "svc/postgres")
    }

    @Test("A file with no connections opens in an older build")
    func emptyFileOpens() throws {
        let bundle = try ConnectionBundle(appVersion: "0.70.0", connections: [])

        let envelope = try OldBuild.decode(ConnectionBundleCodec.encode(bundle))

        #expect(envelope.formatVersion == 1)
        #expect(envelope.connections.isEmpty)
    }

    @Test("The format 1 gate rejects a format 2 file with the newer-version error")
    func gateRejectsVersionTwo() throws {
        let data = try ConnectionBundleCodec.encode(ConnectionBundleCodecTests.fullBundle())

        #expect(throws: OldBuild.Failure.unsupportedVersion(2)) {
            _ = try OldBuild.decode(data)
        }
    }

    @Test("An encrypted format 2 file decrypts on an older build, then reads version 2 with its credentials")
    func encryptedFileDecodesAsVersionTwo() async throws {
        let bundle = try ConnectionBundle(
            appVersion: "0.70.0",
            connections: [BundleConnection(ref: "c1", settings: ConnectionBundleCodecTests.fullSettings(), groupRef: "g2")],
            groups: [BundleGroup(ref: "g1", name: "Client A"), BundleGroup(ref: "g2", name: "Production", parentRef: "g1")],
            credentials: ["c1": ExportableCredentials(
                password: "hunter2",
                sshPassword: nil,
                keyPassphrase: nil,
                sslClientKeyPassphrase: nil,
                totpSecret: nil,
                pluginSecureFields: nil
            )]
        )
        let sealed = try await ConnectionBundleCodec.encode(bundle, passphrase: "pw")

        let json = try await ConnectionExportCrypto.decrypt(data: sealed, passphrase: "pw")
        let envelope = try OldBuild.decodeWithoutGate(json)

        #expect(envelope.formatVersion == 2)
        #expect(envelope.credentials?["c1"]?.password == "hunter2")
    }

    @Test("The newer-version message keeps the text an older build shows")
    func newerVersionMessageIsUnchanged() {
        #expect(
            ConnectionBundleError.unsupportedVersion(2).errorDescription
                == "This file requires a newer version of TablePro (format version 2)"
        )
    }
}

private enum OldBuild {
    enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
    }

    struct Envelope: Decodable {
        let formatVersion: Int
        let exportedAt: Date
        let appVersion: String
        let connections: [Connection]
        let groups: [Group]?
        let tags: [Tag]?
        let credentials: [String: Credentials]?
        let credentialProfiles: [CredentialProfile]?
    }

    struct Connection: Decodable {
        let name: String
        let host: String
        let port: Int
        let database: String
        let username: String
        let type: String
        let sshConfig: SSHConfig?
        let sslConfig: SSLConfig?
        let color: String?
        let tagName: String?
        let tagNames: [String]?
        let groupName: String?
        let sshProfileId: String?
        let sshProfileName: String?
        let credentialProfileName: String?
        let safeModeLevel: String?
        let aiPolicy: String?
        let connectTimeoutSeconds: Int?
        let queryTimeoutSeconds: Int?
        let additionalFields: [String: String]?
        let redisDatabase: Int?
        let startupCommands: String?
        let localOnly: Bool?
        let tunnelCommand: TunnelCommand?
    }

    struct SSHConfig: Decodable {
        let enabled: Bool
        let host: String
        let port: Int?
        let username: String
        let authMethod: String
        let privateKeyPath: String
        let agentSocketPath: String
        let jumpHosts: [JumpHost]?
        let totpMode: String?
        let totpAlgorithm: String?
        let totpDigits: Int?
        let totpPeriod: Int?
        let remoteFilePath: String?
        let remoteFileAccess: String?
    }

    struct JumpHost: Decodable {
        let host: String
        let port: Int?
        let username: String
        let authMethod: String
        let privateKeyPath: String
    }

    struct SSLConfig: Decodable {
        let mode: String
        let caCertificatePath: String?
        let clientCertificatePath: String?
        let clientKeyPath: String?
    }

    struct TunnelCommand: Decodable {
        let method: String
        let command: String?
        let executablePath: String?
        let kubernetesNamespace: String?
        let kubernetesResource: String?
        let kubernetesContext: String?
        let awsTarget: String?
        let awsProfile: String?
        let awsRegion: String?
    }

    struct Group: Decodable {
        let name: String
        let color: String?
    }

    struct Tag: Decodable {
        let name: String
        let color: String?
    }

    struct Credentials: Decodable {
        let password: String?
        let sshPassword: String?
        let keyPassphrase: String?
        let sslClientKeyPassphrase: String?
        let totpSecret: String?
        let pluginSecureFields: [String: String]?
    }

    struct CredentialProfile: Decodable {
        let name: String
        let username: String
        let passwordMode: String
        let secureFieldIds: [String]?
    }

    static func decodeWithoutGate(_ data: Data) throws -> Envelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Envelope.self, from: data)
    }

    static func decode(_ data: Data) throws -> Envelope {
        let envelope = try decodeWithoutGate(data)
        guard envelope.formatVersion <= 1 else { throw Failure.unsupportedVersion(envelope.formatVersion) }
        return envelope
    }
}
