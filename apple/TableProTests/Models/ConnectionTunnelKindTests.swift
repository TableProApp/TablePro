//
//  ConnectionTunnelKindTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro
import TableProSSHConfig

struct ConnectionTunnelKindTests {
    private func connection(
        type: DatabaseType = .postgresql,
        fields: [String: String]? = nil,
        ssh: Bool = false,
        cloudflare: Bool = false,
        cloudSQLProxy: Bool = false,
        socksProxy: Bool = false,
        tunnelCommand: Bool = false
    ) -> DatabaseConnection {
        DatabaseConnection(
            name: "T",
            type: type,
            sshTunnelMode: ssh ? .inline(SSHConfiguration(enabled: true, host: "ssh.example.com")) : .disabled,
            cloudflareTunnelMode: cloudflare
                ? .inline(CloudflareConfiguration(accessHostname: "db.example.com"))
                : .disabled,
            cloudSQLProxyMode: cloudSQLProxy
                ? .inline(CloudSQLProxyConfiguration(instanceConnectionName: "p:r:i"))
                : .disabled,
            socksProxyMode: socksProxy
                ? .inline(SOCKSProxyConfiguration(host: "proxy.example.com"))
                : .disabled,
            tunnelCommandMode: tunnelCommand
                ? .inline(TunnelCommandConfiguration(method: .kubectl, kubernetesResource: "service/pg"))
                : .disabled,
            additionalFields: fields
        )
    }

    private func connection(type: DatabaseType, fields: [String: String]? = nil, only kind: ConnectionTunnelKind) -> DatabaseConnection {
        connection(
            type: type,
            fields: fields,
            ssh: kind == .ssh,
            cloudflare: kind == .cloudflare,
            cloudSQLProxy: kind == .cloudSQLProxy,
            socksProxy: kind == .socksProxy,
            tunnelCommand: kind == .tunnelCommand
        )
    }

    private static let duckdbRemote = ["duckdbMode": "remote", "duckdbHost": "quack.internal", "duckdbPort": "9494"]
    private static let duckdbLocal = ["duckdbMode": "local", "duckdbFilePath": "/tmp/a.duckdb", "duckdbHost": "quack.internal"]

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
        #expect(connection(tunnelCommand: true).activeTunnelKind == .tunnelCommand)
    }

    @Test("every combination of two or more enabled tunnels is a conflict")
    func allCombinations() {
        for mask in 0..<32 {
            let ssh = mask & 1 != 0
            let cloudflare = mask & 2 != 0
            let cloudSQLProxy = mask & 4 != 0
            let socksProxy = mask & 8 != 0
            let tunnelCommand = mask & 16 != 0
            let enabledCount = [ssh, cloudflare, cloudSQLProxy, socksProxy, tunnelCommand].filter { $0 }.count

            let connection = connection(
                ssh: ssh,
                cloudflare: cloudflare,
                cloudSQLProxy: cloudSQLProxy,
                socksProxy: socksProxy,
                tunnelCommand: tunnelCommand
            )
            #expect(connection.enabledTunnelKinds.count == enabledCount)
            if enabledCount == 1 {
                #expect(connection.activeTunnelKind == connection.enabledTunnelKinds.first)
            } else {
                #expect(connection.activeTunnelKind == nil)
            }
        }
    }

    @Test("DuckDB in Remote opens every port forward it stores, since the driver dials the forward")
    func duckdbRemoteOpensItsForward() {
        for kind in ConnectionTunnelKind.formToggleable {
            #expect(connection(type: .duckdb, fields: Self.duckdbRemote, only: kind).activeTunnelKind == kind, "\(kind)")
        }
    }

    @Test("DuckDB in Local File opens none of the port forwards it still stores")
    func duckdbLocalOpensNoForward() {
        for kind in ConnectionTunnelKind.formToggleable {
            let local = connection(type: .duckdb, fields: Self.duckdbLocal, only: kind)
            #expect(local.enabledTunnelKinds.isEmpty, "\(kind) would open a tunnel a file driver goes around")
            #expect(local.activeTunnelKind == nil)
        }
    }

    @Test("a file-based row's stored port forward is not opened")
    func fileBasedRowOpensNoForward() {
        let sqlite = connection(type: .sqlite, ssh: true)
        #expect(sqlite.enabledTunnelKinds.isEmpty)
    }

    /// PGlite offers no SSH, yet its driver dials Host and Port, so a stored tunnel keeps carrying it rather than
    /// turning into a direct dial that would send its traffic in the clear.
    @Test("a network row opens every kind it stores, offered or not")
    func networkRowKeepsItsForward() {
        for kind in ConnectionTunnelKind.formToggleable {
            #expect(connection(type: .pglite, only: kind).activeTunnelKind == kind, "\(kind)")
        }
    }

    @Test("a type the registry does not know opens the tunnel it stores")
    func unknownTypeKeepsItsForward() {
        #expect(connection(type: DatabaseType(rawValue: "NoSuchEngine"), ssh: true).activeTunnelKind == .ssh)
    }
}
