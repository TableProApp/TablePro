import Foundation
import TableProFFI
@testable import TableProMobile
import TableProModels
import TableProSSHTransport
import Testing

struct LibraryRecordMappingTests {
    private func fullConnection() -> DatabaseConnection {
        var ssh = SSHConfiguration(
            host: "bastion.example.com",
            port: 2_222,
            username: "deploy",
            authMethod: .privateKey,
            privateKeyPath: "/keys/id_ed25519",
            jumpHosts: [
                SSHJumpHost(host: "hop.example.com", port: nil, username: "", macAuthMethod: .sshAgent),
                SSHJumpHost(host: "hop2.example.com", port: 22, username: "ops", macAuthMethod: .privateKey, macPrivateKeyPath: "/k")
            ]
        )
        ssh.macEnabled = true
        ssh.macAgentSocketPath = "/tmp/agent.sock"
        ssh.macRemoteFilePath = "/srv/app.db"
        ssh.macRemoteFileAccess = "onServer"
        ssh.totpMode = TOTPMode.autoGenerate.rawValue
        ssh.totpAlgorithm = TOTPAlgorithm.sha256.rawValue
        ssh.totpDigits = 8
        ssh.totpPeriod = 60
        var connection = DatabaseConnection(
            name: "Orders",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            username: "app",
            database: "orders",
            color: .purple,
            iconName: "server.rack",
            isReadOnly: false,
            safeModeLevel: .confirmWrites,
            queryTimeoutSeconds: 45,
            additionalFields: ["connectTimeoutSeconds": "12", LibraryRecordMapping.redisDatabaseKey: "3", "plugin": "value"],
            sshEnabled: true,
            sshConfiguration: ssh,
            sslEnabled: true,
            sslConfiguration: SSLConfiguration(
                mode: .verifyCa,
                caCertificatePath: "/certs/ca.pem",
                clientCertificatePath: "/certs/client.pem",
                clientKeyPath: "/certs/client.key"
            ),
            groupId: UUID(),
            tagIds: [UUID(), UUID()],
            sortOrder: 7,
            isFavorite: true
        )
        connection.sshProfileId = UUID()
        connection.clearsSSHProfileLink = true
        var route = PublishedSSHRoute(
            publisher: UUID(),
            input: PublishedSSHRoute.Input(host: "alias", port: nil, username: "", jumpHosts: []),
            hops: [PublishedSSHRoute.Hop(id: UUID(), alias: "jump", host: "10.0.0.1", port: 22, username: "ops")],
            target: PublishedSSHRoute.Target(alias: "alias", host: "10.0.0.2", port: 22, username: "deploy")
        )
        route.basis = "v1|kept"
        connection.sshRoute = route
        return connection
    }

    @Test("Every field iOS keeps reads back the same after a write to the core's records")
    func everyFieldRoundTrips() {
        let connection = fullConnection()
        let record = LibraryRecordMapping.record(connection, keeping: nil)
        let read = LibraryRecordMapping.connection(record, isFavorite: true)

        #expect(read == connection)
        #expect(record.details.redisDatabase == 3)
        #expect(record.details.additionalFields[LibraryRecordMapping.redisDatabaseKey] == nil)
    }

    @Test("A write of what was read keeps every value only the Mac or the core holds")
    func storedValuesSurviveAnUntouchedWrite() throws {
        let stored = try #require(LibraryRecordMapping.record(fullConnection(), keeping: nil).withMacOnlyValues())
        let read = LibraryRecordMapping.connection(stored, isFavorite: false)

        #expect(read.safeModeLevel == .confirmWrites)
        #expect(read.sslConfiguration?.mode == .verifyFull)
        #expect(read.color == .none)
        #expect(LibraryRecordMapping.record(read, keeping: stored) == stored)
    }

    @Test("An edit writes the value iOS shows, and keeps what it does not touch")
    func editReplacesOnlyWhatChanged() throws {
        let stored = try #require(LibraryRecordMapping.record(fullConnection(), keeping: nil).withMacOnlyValues())
        var read = LibraryRecordMapping.connection(stored, isFavorite: false)
        read.safeModeLevel = .readOnly
        read.name = "Renamed"

        let written = LibraryRecordMapping.record(read, keeping: stored)

        #expect(written.connection.safeMode == .readOnly)
        #expect(written.connection.name == "Renamed")
        #expect(written.connection.tls == stored.connection.tls)
        #expect(written.connection.color == "teal")
        #expect(written.connection.aiPolicy == .never)
        #expect(written.details.startupSql == "SET search_path = app")
        #expect(written.device.origin == "imported")
    }

    @Test("Each Safe Mode level reads as the iOS level that runs it, and a Mac level stays until iOS changes it")
    func safeModeLevels() {
        let expected: [(SafeModeTag, SafeModeLevel)] = [
            (.silent, .off), (.alert, .confirmWrites), (.alertFull, .confirmWrites),
            (.safeMode, .confirmWrites), (.safeModeFull, .confirmWrites), (.readOnly, .readOnly)
        ]
        for (tag, level) in expected {
            #expect(LibraryRecordMapping.safeMode(tag) == level)
            #expect(LibraryRecordMapping.safeModeTag(level, keeping: tag) == tag)
        }
        #expect(LibraryRecordMapping.safeModeTag(.off, keeping: .safeModeFull) == .silent)
        #expect(LibraryRecordMapping.safeModeTag(.confirmWrites, keeping: nil) == .alert)
    }

    @Test("The Mac's Preferred and an older build's require keep what each says through the core")
    func sslModes() {
        let preferred = SSLConfiguration(mode: .require, isMacPreferred: true)
        #expect(LibraryRecordMapping.tlsSettings(preferred, keeping: nil).mode == .prefer)

        let legacy = SSLConfiguration(mode: .require, isLegacyRequire: true)
        let settings = LibraryRecordMapping.tlsSettings(legacy, keeping: nil)
        #expect(settings.mode == .require)
        #expect(LibraryRecordMapping.sslConfiguration(settings, legacyRequire: true) == legacy)

        var switchedOn = DatabaseConnection(name: "Orders", type: .mssql, sslEnabled: true)
        switchedOn.sslConfiguration = nil
        let required = LibraryRecordMapping.record(switchedOn, keeping: nil).connection.tls
        #expect(required.mode == .require)
        #expect(LibraryRecordMapping.record(switchedOn, keeping: LibraryRecordMapping.record(switchedOn, keeping: nil)).connection.tls == required)

        let none = LibraryRecordMapping.tlsSettings(nil, keeping: nil)
        #expect(none.mode == .disable)
        #expect(LibraryRecordMapping.sslConfiguration(none, legacyRequire: false) == nil)
    }

    @Test("Groups and tags read back the same, and a colour iOS cannot show stays")
    func groupsAndTags() {
        let group = ConnectionGroup(name: "Team", sortOrder: 3, color: .blue, iconName: "folder", parentId: UUID())
        #expect(LibraryRecordMapping.group(LibraryRecordMapping.record(group, keeping: nil)) == group)

        let tag = ConnectionTag(name: "prod", isPreset: true, color: .gray)
        let tagRecord = LibraryRecordMapping.record(tag, keeping: nil)
        #expect(tagRecord.color == "slate")
        #expect(LibraryRecordMapping.tag(tagRecord) == tag)

        var teal = tagRecord
        teal.color = "teal"
        #expect(LibraryRecordMapping.record(LibraryRecordMapping.tag(teal), keeping: teal) == teal)
    }

    @Test("A hop with no id, as another app types it, gets the same id on every read")
    func hopWithoutIdIsStable() throws {
        var record = LibraryRecordMapping.record(fullConnection(), keeping: nil)
        // As the core gives ids back.
        record.connection.id = record.connection.id.lowercased()
        var ssh = try #require(record.connection.ssh)
        ssh.jumpHosts = [SshJumpHostRecord(id: nil, host: "typed", port: nil, username: nil, auth: nil, keyPath: nil)]
        record.connection.ssh = ssh

        let first = LibraryRecordMapping.connection(record, isFavorite: false)
        let second = LibraryRecordMapping.connection(record, isFavorite: false)

        #expect(first.sshConfiguration?.jumpHosts.map(\.id) == second.sshConfiguration?.jumpHosts.map(\.id))
        #expect(LibraryRecordMapping.record(first, keeping: record).connection.ssh == record.connection.ssh)
    }
}

private extension LibraryConnectionRecord {
    // What a Mac writes that iOS has no case for.
    func withMacOnlyValues() -> LibraryConnectionRecord? {
        var record = self
        record.connection.safeMode = .alertFull
        record.connection.tls = TlsSettings(
            mode: .strict,
            caFile: "/certs/ca.pem",
            clientCertificate: nil,
            clientKey: nil,
            serverName: "db.internal"
        )
        record.connection.color = "teal"
        record.connection.aiPolicy = .never
        record.connection.externalAccess = .readWrite
        record.connection.integratedAuth = true
        record.connection.lastOpenedMs = 1_700_000_000_000
        guard var ssh = record.connection.ssh else { return nil }
        ssh.auth = .privateKey(path: "/keys/id_ed25519", hasPassphrase: true)
        ssh.jumpHosts[0].auth = nil
        record.connection.ssh = ssh
        record.details.startupSql = "SET search_path = app"
        record.details.aiRules = "Read only"
        record.details.credentialReference = .env(variable: "PGPASSWORD")
        record.device.origin = "imported"
        return record
    }
}
