//
//  ConnectionTunnelKindTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Connection tunnel kind")
struct ConnectionTunnelKindTests {
    private func connection(
        ssh: Bool = false,
        cloudflare: Bool = false,
        cloudSQLProxy: Bool = false,
        socksProxy: Bool = false
    ) -> DatabaseConnection {
        DatabaseConnection(
            name: "T",
            type: .postgresql,
            sshTunnelMode: ssh ? .inline(SSHConfiguration(enabled: true, host: "ssh.example.com")) : .disabled,
            cloudflareTunnelMode: cloudflare
                ? .inline(CloudflareConfiguration(accessHostname: "db.example.com"))
                : .disabled,
            cloudSQLProxyMode: cloudSQLProxy
                ? .inline(CloudSQLProxyConfiguration(instanceConnectionName: "p:r:i"))
                : .disabled,
            socksProxyMode: socksProxy
                ? .inline(SOCKSProxyConfiguration(host: "proxy.example.com"))
                : .disabled
        )
    }

    @Test("no tunnel has no active kind")
    func none() {
        let connection = connection()
        #expect(connection.enabledTunnelKinds.isEmpty)
        #expect(connection.activeTunnelKind == nil)
    }

    @Test("a single enabled tunnel resolves to that kind")
    func single() {
        #expect(connection(ssh: true).activeTunnelKind == .ssh)
        #expect(connection(cloudflare: true).activeTunnelKind == .cloudflare)
        #expect(connection(cloudSQLProxy: true).activeTunnelKind == .cloudSQLProxy)
        #expect(connection(socksProxy: true).activeTunnelKind == .socksProxy)
    }

    @Test("every combination of two or more enabled tunnels is a conflict")
    func allCombinations() {
        for mask in 0..<16 {
            let ssh = mask & 1 != 0
            let cloudflare = mask & 2 != 0
            let cloudSQLProxy = mask & 4 != 0
            let socksProxy = mask & 8 != 0
            let enabledCount = [ssh, cloudflare, cloudSQLProxy, socksProxy].filter { $0 }.count

            let connection = connection(
                ssh: ssh,
                cloudflare: cloudflare,
                cloudSQLProxy: cloudSQLProxy,
                socksProxy: socksProxy
            )
            #expect(connection.enabledTunnelKinds.count == enabledCount)
            if enabledCount == 1 {
                #expect(connection.activeTunnelKind == connection.enabledTunnelKinds.first)
            } else {
                #expect(connection.activeTunnelKind == nil)
            }
        }
    }
}
