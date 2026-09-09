//
//  ExternalConnectionSSHDisclosureTests.swift
//  TableProTests
//
//  The alert asks the user to decide whether they trust an external link. A tunnelled connection's
//  database host is the far end of the tunnel, usually localhost, so naming it alone describes none
//  of the machines the session crosses.
//

import AppKit
import TableProPluginKit
@testable import TablePro
import Testing

@Suite("External connection SSH disclosure")
@MainActor
struct ExternalConnectionSSHDisclosureTests {
    private func tunnelled(
        host: String = "127.0.0.1",
        sshHost: String = "bastion.example.com",
        sshPort: Int? = nil,
        sshUsername: String = "ops",
        jumpHosts: [SSHJumpHost] = []
    ) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "External", type: .mysql)
        connection.host = host
        connection.port = 3_306
        connection.database = "app"
        connection.username = "dbuser"
        connection.sshConfig.enabled = true
        connection.sshConfig.host = sshHost
        connection.sshConfig.port = sshPort
        connection.sshConfig.username = sshUsername
        connection.sshConfig.jumpHosts = jumpHosts
        return connection
    }

    private func informativeText(for connection: DatabaseConnection) -> String {
        ExternalConnectionAlertPrompt.makeAlert(for: connection, offerAlwaysAllow: false).informativeText
    }

    @Test("The SSH server the session tunnels through is named")
    func namesTheSSHServer() {
        let text = informativeText(for: tunnelled())
        #expect(text.contains("ops@bastion.example.com:22"))
    }

    @Test("A non-default SSH port is shown")
    func showsNonDefaultPort() {
        let text = informativeText(for: tunnelled(sshPort: 2_222))
        #expect(text.contains("bastion.example.com:2222"))
    }

    @Test("An SSH server with no username is still named")
    func namesServerWithoutUsername() {
        let text = informativeText(for: tunnelled(sshUsername: ""))
        #expect(text.contains("bastion.example.com:22"))
    }

    @Test("Every jump host is named")
    func namesEveryJumpHost() {
        var first = SSHJumpHost()
        first.host = "edge.example.com"
        first.username = "relay"
        var second = SSHJumpHost()
        second.host = "inner.example.com"
        second.port = 2_200

        let text = informativeText(for: tunnelled(jumpHosts: [first, second]))
        #expect(text.contains("relay@edge.example.com:22"))
        #expect(text.contains("inner.example.com:2200"))
    }

    @Test("A connection with no tunnel says nothing about SSH")
    func staysQuietWithoutATunnel() {
        var connection = DatabaseConnection(name: "External", type: .postgresql)
        connection.host = "db.example.com"
        connection.port = 5_432
        #expect(!informativeText(for: connection).contains("SSH"))
    }

    /// `enabled` is the switch the form actually toggles, so a host left behind by a disabled
    /// tunnel must not be presented as one the session will cross.
    @Test("A disabled tunnel is not reported as one")
    func staysQuietWhenTheTunnelIsOff() {
        var connection = tunnelled()
        connection.sshConfig.enabled = false
        #expect(!informativeText(for: connection).contains("bastion.example.com"))
    }

    @Test("The database host is still shown alongside the tunnel")
    func keepsTheDatabaseDetails() {
        let text = informativeText(for: tunnelled())
        #expect(text.contains("127.0.0.1:3306"))
        #expect(text.contains("dbuser"))
        #expect(text.contains("app"))
    }
}
