import Foundation
import Testing

@testable import TableProModels

struct DatabaseConnectionSwitchTests {
    private func reloaded(_ connection: DatabaseConnection) throws -> DatabaseConnection {
        try JSONDecoder().decode(DatabaseConnection.self, from: JSONEncoder().encode(connection))
    }

    @Test("A stored copy whose tunnel switch disagrees with the Mac's takes the Mac's", arguments: [true, false])
    func sshSwitchFollowsTheConfiguration(_ macEnabled: Bool) throws {
        var ssh = SSHConfiguration(host: "bastion.example.com", username: "deploy")
        ssh.macEnabled = macEnabled
        let stored = DatabaseConnection(name: "Orders", sshEnabled: !macEnabled, sshConfiguration: ssh)

        #expect(try reloaded(stored).sshEnabled == macEnabled)
    }

    @Test("A tunnel configuration without the Mac's switch keeps the stored one", arguments: [true, false])
    func sshSwitchWithoutMacValueStays(_ enabled: Bool) throws {
        let ssh = SSHConfiguration(host: "bastion.example.com", username: "deploy")
        let stored = DatabaseConnection(name: "Orders", sshEnabled: enabled, sshConfiguration: ssh)

        #expect(try reloaded(stored).sshEnabled == enabled)
    }

    @Test("A stored copy that reads SSL off over a Mac SSL mode takes the mode")
    func sslSwitchFollowsTheConfiguration() throws {
        let required = DatabaseConnection(name: "Orders", sslEnabled: false, sslConfiguration: SSLConfiguration(mode: .verifyFull))
        let disabled = DatabaseConnection(name: "Orders", sslEnabled: true, sslConfiguration: SSLConfiguration(mode: .disable))
        let unset = DatabaseConnection(name: "Orders", sslEnabled: true)

        #expect(try reloaded(required).sslEnabled)
        #expect(try !reloaded(disabled).sslEnabled)
        #expect(try reloaded(unset).sslEnabled)
    }
}
