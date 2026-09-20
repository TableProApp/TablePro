import Foundation
@testable import TableProMobile
import TableProModels
import TableProOracleCore
import Testing

@MainActor
@Suite("Connection form edits")
struct ConnectionFormEditsTests {
    private func storedConnection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Prod",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            username: "app",
            database: "app",
            sslEnabled: true,
            sslConfiguration: SSLConfiguration(mode: .require),
            tagIds: [UUID()],
            sortOrder: 2
        )
    }

    @Test("A port edit keeps every change made to the record after the form opened")
    func keepsChangesMadeWhileOpen() {
        let snapshot = storedConnection()
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        let groupId = UUID()
        let otherTag = UUID()
        var current = snapshot
        current.isFavorite = true
        current.color = .purple
        current.groupId = groupId
        current.tagIds = snapshot.tagIds + [otherTag]
        current.sortOrder = 9
        current.queryTimeoutSeconds = 45

        viewModel.port = "5433"
        let saved = viewModel.applyingEdits(to: current)

        #expect(saved.port == 5_433)
        #expect(saved.isFavorite)
        #expect(saved.color == .purple)
        #expect(saved.groupId == groupId)
        #expect(saved.tagIds == snapshot.tagIds + [otherTag])
        #expect(saved.sortOrder == 9)
        #expect(saved.queryTimeoutSeconds == 45)
    }

    @Test("An untouched form hands back the current record unchanged")
    func untouchedFormChangesNothing() {
        let snapshot = storedConnection()
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        var current = snapshot
        current.host = "replica.example.com"
        current.name = "Renamed on the Mac"

        #expect(viewModel.applyingEdits(to: current) == current)
    }

    @Test("A name typed here wins while a host changed elsewhere survives")
    func typedNameAndSyncedHostBothLand() {
        let snapshot = storedConnection()
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        var current = snapshot
        current.host = "replica.example.com"

        viewModel.name = "Production"
        let saved = viewModel.applyingEdits(to: current)

        #expect(saved.name == "Production")
        #expect(saved.host == "replica.example.com")
    }

    @Test("A tag pick replaces only the first of the tags the record holds now")
    func tagPickReplacesTheCurrentFirstTag() {
        let snapshot = storedConnection()
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        let macFirst = UUID()
        let macSecond = UUID()
        let picked = UUID()
        var current = snapshot
        current.tagIds = [macFirst, macSecond]

        viewModel.tagId = picked
        let saved = viewModel.applyingEdits(to: current)

        #expect(saved.tagIds == [picked, macSecond])
    }

    @Test("An SSH port edit keeps the jump hosts and the Mac's own tunnel settings")
    func sshEditKeepsMacFields() {
        var ssh = SSHConfiguration(host: "bastion.example.com", port: 22, username: "deploy")
        ssh.jumpHosts = [SSHJumpHost(host: "jump.example.com")]
        ssh.macTotpMode = "autoGenerate"
        ssh.macAgentSocketPath = "/tmp/agent.sock"
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = ssh
        let viewModel = ConnectionFormViewModel(editing: snapshot)

        viewModel.sshPort = "2222"
        let saved = viewModel.applyingEdits(to: snapshot)

        #expect(saved.sshConfiguration?.port == 2_222)
        #expect(saved.sshConfiguration?.jumpHosts == ssh.jumpHosts)
        #expect(saved.sshConfiguration?.macTotpMode == "autoGenerate")
        #expect(saved.sshConfiguration?.macAgentSocketPath == "/tmp/agent.sock")
    }

    @Test("A tunnel the Mac left without a port keeps it unset when another field is edited")
    func sshEditKeepsUnsetPort() {
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = SSHConfiguration(host: "bastion.example.com", username: "deploy")
        let viewModel = ConnectionFormViewModel(editing: snapshot)

        viewModel.sshUsername = "ops"
        let saved = viewModel.applyingEdits(to: snapshot)

        #expect(saved.sshConfiguration?.port == nil)
        #expect(saved.sshConfiguration?.username == "ops")
    }

    @Test("An SSH port edit keeps an SSH host that synced in while the form was open")
    func sshPortEditKeepsSyncedHost() {
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = SSHConfiguration(host: "bastion-old.example.com", port: 22, username: "deploy")
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        var current = snapshot
        current.sshConfiguration?.host = "bastion-new.example.com"
        current.sshConfiguration?.authMethod = .privateKey

        viewModel.sshPort = "2222"
        let saved = viewModel.applyingEdits(to: current)

        #expect(saved.sshConfiguration?.host == "bastion-new.example.com")
        #expect(saved.sshConfiguration?.authMethod == .privateKey)
        #expect(saved.sshConfiguration?.port == 2_222)
        #expect(saved.sshConfiguration?.username == "deploy")
        #expect(saved.sshEnabled)
    }

    @Test("An SSH edit keeps a tunnel another device turned off")
    func sshEditKeepsSyncedTunnelOff() {
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = SSHConfiguration(host: "bastion.example.com", port: 22, username: "deploy")
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        var current = snapshot
        current.sshEnabled = false

        viewModel.sshUsername = "ops"
        let saved = viewModel.applyingEdits(to: current)

        #expect(saved.sshEnabled == false)
        #expect(saved.sshConfiguration?.username == "ops")
        #expect(saved.sshConfiguration?.host == "bastion.example.com")
    }

        @Test("Turning SSH on over a tunnel the Mac had switched off switches it on there too")
    func sshOnFlipsMacEnabled() {
        var ssh = SSHConfiguration(host: "bastion.example.com", port: 22, username: "deploy")
        ssh.macEnabled = false
        var snapshot = storedConnection()
        snapshot.sshEnabled = false
        snapshot.sshConfiguration = ssh
        let viewModel = ConnectionFormViewModel(editing: snapshot)

        viewModel.sshEnabled = true
        viewModel.sshHost = "bastion.example.com"
        viewModel.sshUsername = "deploy"
        let saved = viewModel.applyingEdits(to: snapshot)

        #expect(saved.sshEnabled)
        #expect(saved.sshConfiguration?.macEnabled == true)
    }

    @Test("Turning SSH off clears the tunnel")
    func sshOffClearsTheTunnel() {
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = SSHConfiguration(host: "bastion.example.com", port: 22, username: "deploy")
        let viewModel = ConnectionFormViewModel(editing: snapshot)

        viewModel.sshEnabled = false
        let saved = viewModel.applyingEdits(to: snapshot)

        #expect(!saved.sshEnabled)
        #expect(saved.sshConfiguration == nil)
    }

    @Test("An SSL mode change keeps certificate paths set after the form opened")
    func sslChangeKeepsNewCertificatePaths() {
        let snapshot = storedConnection()
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        var current = snapshot
        current.sslConfiguration = SSLConfiguration(mode: .require, caCertificatePath: "/Users/mac/ca.pem")

        viewModel.sslMode = .verifyFull
        let saved = viewModel.applyingEdits(to: current)

        #expect(saved.sslConfiguration?.mode == .verifyFull)
        #expect(saved.sslConfiguration?.caCertificatePath == "/Users/mac/ca.pem")
        #expect(saved.sslEnabled)
    }

    @Test("An Oracle edit keeps additional fields added after the form opened")
    func oracleEditKeepsNewFields() {
        let snapshot = DatabaseConnection(
            name: "Oracle",
            type: .oracle,
            host: "db.example.com",
            port: 1_521,
            additionalFields: [OracleConnectionOptions.AdditionalFieldKey.serviceName: "ORCL"]
        )
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        var current = snapshot
        current.additionalFields["custom"] = "kept"

        viewModel.oracleServiceName = "ORCLPDB1"
        let saved = viewModel.applyingEdits(to: current)

        #expect(saved.additionalFields[OracleConnectionOptions.AdditionalFieldKey.serviceName] == "ORCLPDB1")
        #expect(saved.additionalFields["custom"] == "kept")
    }

    @Test("An Oracle service name edit keeps a SID and role that synced in while the form was open")
    func oracleServiceNameEditKeepsSyncedFields() {
        typealias Key = OracleConnectionOptions.AdditionalFieldKey
        let snapshot = DatabaseConnection(
            name: "Oracle",
            type: .oracle,
            host: "db.example.com",
            port: 1_521,
            additionalFields: [Key.serviceName: "ORCL", Key.sid: "OLDSID"]
        )
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        var current = snapshot
        current.additionalFields[Key.sid] = "NEWSID"
        current.additionalFields[Key.role] = OracleConnectionOptions.Role.sysdba.rawValue

        viewModel.oracleServiceName = "ORCLPDB1"
        let saved = viewModel.applyingEdits(to: current)

        #expect(saved.additionalFields[Key.serviceName] == "ORCLPDB1")
        #expect(saved.additionalFields[Key.sid] == "NEWSID")
        #expect(saved.additionalFields[Key.role] == OracleConnectionOptions.Role.sysdba.rawValue)
    }

        @Test("A Safe Mode change writes the legacy read-only flag with it")
    func safeModeWritesReadOnly() {
        let snapshot = storedConnection()
        let viewModel = ConnectionFormViewModel(editing: snapshot)

        viewModel.safeModeLevel = .readOnly
        let saved = viewModel.applyingEdits(to: snapshot)

        #expect(saved.safeModeLevel == .readOnly)
        #expect(saved.isReadOnly)
    }
}
