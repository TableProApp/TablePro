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

    @Test("Editing a connection that uses a Mac socket keeps the socket path")
    func editKeepsMacSocketPath() {
        let snapshot = DatabaseConnection(
            name: "Local",
            type: .mysql,
            host: "localhost",
            additionalFields: [MySQLLocalSocket.fieldKey: "/tmp/mysql.sock"]
        )
        let viewModel = ConnectionFormViewModel(editing: snapshot)

        viewModel.name = "Local MySQL"
        viewModel.host = "127.0.0.1"
        viewModel.port = "3307"

        #expect(viewModel.applyingEdits(to: snapshot).additionalFields[MySQLLocalSocket.fieldKey] == "/tmp/mysql.sock")
        #expect(viewModel.buildConnection().additionalFields[MySQLLocalSocket.fieldKey] == "/tmp/mysql.sock")
    }

    @Test("An SSH port edit keeps the jump hosts and the Mac's own tunnel settings")
    func sshEditKeepsMacFields() {
        var ssh = SSHConfiguration(host: "bastion.example.com", port: 22, username: "deploy")
        ssh.jumpHosts = [SSHJumpHost(host: "jump.example.com")]
        ssh.totpMode = "autoGenerate"
        ssh.macAgentSocketPath = "/tmp/agent.sock"
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = ssh
        let viewModel = ConnectionFormViewModel(editing: snapshot)

        viewModel.sshPort = "2222"
        let saved = viewModel.applyingEdits(to: snapshot)

        #expect(saved.sshConfiguration?.port == 2_222)
        #expect(saved.sshConfiguration?.jumpHosts == ssh.jumpHosts)
        #expect(saved.sshConfiguration?.totpMode == "autoGenerate")
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

    @Test("A tunnel turned on in a new connection is written switched on for the Mac")
    func newTunnelWritesMacEnabled() throws {
        let viewModel = ConnectionFormViewModel()
        viewModel.host = "db.example.com"
        viewModel.sshEnabled = true
        viewModel.sshHost = "bastion.example.com"
        viewModel.sshUsername = "deploy"

        let saved = viewModel.buildConnection()
        let encoded = try JSONEncoder().encode(try #require(saved.sshConfiguration))
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(saved.sshEnabled)
        #expect(saved.sshConfiguration?.macEnabled == true)
        #expect(json["enabled"] as? Bool == true)
    }

    @Test("An SSH edit on a tunnel that never stored the Mac's switch writes it on")
    func sshEditWritesMissingMacEnabled() {
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = SSHConfiguration(host: "bastion.example.com", port: 22, username: "deploy")
        let viewModel = ConnectionFormViewModel(editing: snapshot)

        viewModel.sshPort = "2222"
        let saved = viewModel.applyingEdits(to: snapshot)

        #expect(saved.sshConfiguration?.macEnabled == true)
    }

    @Test("Removing, reordering and adding hops keeps each remaining hop's Mac credential")
    func hopListEditsKeepMacFieldsById() throws {
        let first = SSHJumpHost(
            host: "bastion1.example.com", username: "ops",
            macAuthMethod: .privateKey, macPrivateKeyPath: "/Users/me/.ssh/bastion1"
        )
        let second = SSHJumpHost(host: "bastion2.internal", username: "ops")
        let third = SSHJumpHost(
            host: "bastion3.internal", port: 2_222, username: "ops",
            macAuthMethod: .privateKey, macPrivateKeyPath: "/Users/me/.ssh/bastion3"
        )
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = SSHConfiguration(
            host: "db-ssh.internal", username: "deploy", jumpHosts: [first, second, third]
        )
        let viewModel = ConnectionFormViewModel(editing: snapshot)

        viewModel.removeJumpHosts(atOffsets: IndexSet(integer: 1))
        viewModel.moveJumpHosts(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        let added = viewModel.addJumpHost()
        viewModel.updateJumpHost(added) { $0.host = "bastion4.internal" }
        let saved = try #require(viewModel.applyingEdits(to: snapshot).sshConfiguration)

        let ids = saved.jumpHosts.map { $0.id }
        #expect(ids == [third.id, first.id, added])
        #expect(saved.jumpHosts[0] == third)
        #expect(saved.jumpHosts[1] == first)
        #expect(saved.jumpHosts[2].host == "bastion4.internal")
        #expect(saved.jumpHosts[2].port == nil)
        #expect(saved.jumpHosts[2].macAuthMethod == .sshAgent)
        #expect(saved.jumpHosts[2].macPrivateKeyPath.isEmpty)
    }

    @Test("A hop edit keeps a Mac edit to that hop and a hop the Mac added while the form was open")
    func hopEditKeepsMacEditsAndMacHops() throws {
        let first = SSHJumpHost(host: "bastion1.example.com", username: "ops")
        let second = SSHJumpHost(host: "bastion2.internal", username: "ops")
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = SSHConfiguration(
            host: "db-ssh.internal", username: "deploy", jumpHosts: [first, second]
        )
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        let macAdded = SSHJumpHost(host: "bastion3.internal", username: "ops")
        var current = snapshot
        current.sshConfiguration?.jumpHosts[0].host = "bastion1-new.example.com"
        current.sshConfiguration?.jumpHosts[0].macAuthMethod = .privateKey
        current.sshConfiguration?.jumpHosts[0].macPrivateKeyPath = "/Users/me/.ssh/bastion1"
        current.sshConfiguration?.jumpHosts.append(macAdded)

        viewModel.updateJumpHost(first.id) { $0.username = "admin" }
        let saved = try #require(viewModel.applyingEdits(to: current).sshConfiguration)

        let ids = saved.jumpHosts.map { $0.id }
        #expect(ids == [first.id, second.id, macAdded.id])
        #expect(saved.jumpHosts[0].username == "admin")
        #expect(saved.jumpHosts[0].host == "bastion1-new.example.com")
        #expect(saved.jumpHosts[0].macAuthMethod == .privateKey)
        #expect(saved.jumpHosts[0].macPrivateKeyPath == "/Users/me/.ssh/bastion1")
        #expect(saved.jumpHosts[2] == macAdded)
    }

    @Test("A hop removed in the form stays removed while one the Mac added survives")
    func removedHopStaysRemoved() throws {
        let first = SSHJumpHost(host: "bastion1.example.com", username: "ops")
        let second = SSHJumpHost(host: "bastion2.internal", username: "ops")
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = SSHConfiguration(
            host: "db-ssh.internal", username: "deploy", jumpHosts: [first, second]
        )
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        let macAdded = SSHJumpHost(host: "bastion3.internal", username: "ops")
        var current = snapshot
        current.sshConfiguration?.jumpHosts.append(macAdded)

        viewModel.removeJumpHosts(atOffsets: IndexSet(integer: 0))
        let saved = try #require(viewModel.applyingEdits(to: current).sshConfiguration)

        let ids = saved.jumpHosts.map { $0.id }
        #expect(ids == [second.id, macAdded.id])
    }

    @Test("A hop field edit keeps the chain another device saved while the form was open")
    func hopFieldEditKeepsTheRecordsChain() throws {
        let first = SSHJumpHost(host: "bastion1.example.com", username: "ops")
        let removed = SSHJumpHost(host: "bastion2.internal", username: "ops")
        let last = SSHJumpHost(host: "bastion3.internal", username: "ops")
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = SSHConfiguration(
            host: "db-ssh.internal", username: "deploy", jumpHosts: [first, removed, last]
        )
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        let inserted = SSHJumpHost(host: "bastion-mid.internal", username: "ops")
        var current = snapshot
        current.sshConfiguration?.jumpHosts = [first, inserted, last]

        viewModel.updateJumpHost(first.id) { $0.username = "admin" }
        viewModel.updateJumpHost(removed.id) { $0.port = "2222" }
        let saved = try #require(viewModel.applyingEdits(to: current).sshConfiguration)

        let ids = saved.jumpHosts.map { $0.id }
        #expect(ids == [first.id, inserted.id, last.id])
        #expect(saved.jumpHosts[0].username == "admin")
    }

    @Test("Reordering and adding hops leaves out a hop removed elsewhere and keeps one inserted elsewhere in place")
    func hopListEditMergesTheRecordsChain() throws {
        let first = SSHJumpHost(host: "bastion1.example.com", username: "ops")
        let removed = SSHJumpHost(host: "bastion2.internal", username: "ops")
        let last = SSHJumpHost(host: "bastion3.internal", username: "ops")
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = SSHConfiguration(
            host: "db-ssh.internal", username: "deploy", jumpHosts: [first, removed, last]
        )
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        let inserted = SSHJumpHost(host: "bastion-mid.internal", username: "ops")
        var current = snapshot
        current.sshConfiguration?.jumpHosts = [first, inserted, last]

        viewModel.moveJumpHosts(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        let added = viewModel.addJumpHost()
        viewModel.updateJumpHost(added) { $0.host = "bastion4.internal" }
        let saved = try #require(viewModel.applyingEdits(to: current).sshConfiguration)

        let ids = saved.jumpHosts.map { $0.id }
        #expect(ids == [last.id, first.id, inserted.id, added])
    }

    @Test("An SSH edit that leaves the hops alone keeps a hop order the Mac set while the form was open")
    func untouchedHopsKeepMacOrder() throws {
        let first = SSHJumpHost(host: "bastion1.example.com", username: "ops")
        let second = SSHJumpHost(host: "bastion2.internal", username: "ops")
        var snapshot = storedConnection()
        snapshot.sshEnabled = true
        snapshot.sshConfiguration = SSHConfiguration(
            host: "db-ssh.internal", username: "deploy", jumpHosts: [first, second]
        )
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        var current = snapshot
        current.sshConfiguration?.jumpHosts = [second, first]

        viewModel.sshPort = "2222"
        let saved = try #require(viewModel.applyingEdits(to: current).sshConfiguration)

        #expect(saved.jumpHosts == [second, first])
        #expect(saved.port == 2_222)
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

    @Test("An edit that leaves the icon alone keeps an icon set on the Mac while the form was open")
    func untouchedIconKeepsMacIcon() {
        let snapshot = storedConnection()
        let viewModel = ConnectionFormViewModel(editing: snapshot)
        var current = snapshot
        current.iconName = "server.rack"

        viewModel.port = "5433"
        let saved = viewModel.applyingEdits(to: current)

        #expect(saved.port == 5_433)
        #expect(saved.iconName == "server.rack")
    }

    @Test("Picking an icon writes it, and picking Default clears it")
    func iconPickAndReset() {
        var snapshot = storedConnection()
        let picking = ConnectionFormViewModel(editing: snapshot)
        picking.iconName = "flame"
        snapshot = picking.applyingEdits(to: snapshot)
        #expect(snapshot.iconName == "flame")

        let resetting = ConnectionFormViewModel(editing: snapshot)
        #expect(resetting.iconName == "flame")
        resetting.iconName = nil
        #expect(resetting.hasChanges)
        #expect(resetting.applyingEdits(to: snapshot).iconName == nil)
    }

    @Test("An icon this release does not know survives an edit that did not touch it")
    func unknownIconSurvivesAnEdit() {
        var snapshot = storedConnection()
        snapshot.iconName = "made.up.symbol"
        let viewModel = ConnectionFormViewModel(editing: snapshot)

        viewModel.name = "Renamed"
        let saved = viewModel.applyingEdits(to: snapshot)

        #expect(saved.name == "Renamed")
        #expect(saved.iconName == "made.up.symbol")
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
