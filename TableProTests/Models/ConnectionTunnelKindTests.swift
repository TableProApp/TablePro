//
//  ConnectionTunnelKindTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Connection tunnel kind")
struct ConnectionTunnelKindTests {
    private func connection(ssh: Bool, cloudflare: Bool, proxy: Bool) -> DatabaseConnection {
        DatabaseConnection(
            name: "T",
            type: .postgresql,
            sshTunnelMode: ssh ? .inline(SSHConfiguration(enabled: true, host: "ssh.example.com")) : .disabled,
            cloudflareTunnelMode: cloudflare
                ? .inline(CloudflareConfiguration(accessHostname: "db.example.com"))
                : .disabled,
            cloudSQLProxyMode: proxy
                ? .inline(CloudSQLProxyConfiguration(instanceConnectionName: "p:r:i"))
                : .disabled
        )
    }

    @Test("no tunnel has no active kind")
    func none() {
        let connection = connection(ssh: false, cloudflare: false, proxy: false)
        #expect(connection.enabledTunnelKinds.isEmpty)
        #expect(connection.activeTunnelKind == nil)
    }

    @Test("a single enabled tunnel resolves to that kind")
    func single() {
        #expect(connection(ssh: true, cloudflare: false, proxy: false).activeTunnelKind == .ssh)
        #expect(connection(ssh: false, cloudflare: true, proxy: false).activeTunnelKind == .cloudflare)
        #expect(connection(ssh: false, cloudflare: false, proxy: true).activeTunnelKind == .cloudSQLProxy)
    }

    @Test("two enabled tunnels are a conflict with no active kind")
    func twoConflict() {
        for combo in [(true, true, false), (true, false, true), (false, true, true)] {
            let connection = connection(ssh: combo.0, cloudflare: combo.1, proxy: combo.2)
            #expect(connection.enabledTunnelKinds.count == 2)
            #expect(connection.activeTunnelKind == nil)
        }
    }

    @Test("all three enabled is a conflict with no active kind")
    func threeConflict() {
        let connection = connection(ssh: true, cloudflare: true, proxy: true)
        #expect(connection.enabledTunnelKinds.count == 3)
        #expect(connection.activeTunnelKind == nil)
    }
}
