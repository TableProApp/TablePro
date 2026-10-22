//
//  LocalNetworkAccessDiagnosisTests.swift
//  TableProTests
//
//  The permission is asked of the host this Mac dials: the database for a direct connection, the
//  first SSH hop or the SOCKS proxy behind a transport, never the server those reach for it.
//

import Foundation
@testable import TablePro
import TableProPluginKit
@testable import TableProSSHConfig
import Testing

struct LocalNetworkAccessDiagnosisTests {
    private struct StubProbe: LocalNetworkAccessProbing {
        let denied: Set<String>

        func access(to host: String) async -> LocalNetworkAccess {
            denied.contains(host) ? .denied : .granted
        }
    }

    private struct RouteRefusal: LocalizedError {
        var errorDescription: String? { "could not connect to server: No route to host" }
    }

    private func hops(_ connection: DatabaseConnection, sshConfig: String = "") -> [LocalNetworkHop] {
        LocalNetworkAccessDiagnosis.hops(for: connection, sshDocument: SSHConfigParser.parseDocumentContent(sshConfig))
    }

    private func sshConnection(_ config: SSHConfiguration) -> DatabaseConnection {
        var connection = DatabaseConnection(name: "Behind SSH", host: "10.20.0.4", port: 5_432, type: .postgresql)
        connection.sshTunnelMode = .inline(config)
        return connection
    }

    @Test("A direct connection asks about the database host")
    func directConnectionProbesTheDatabase() {
        let connection = DatabaseConnection(name: "LAN", host: "192.168.1.20", port: 5_432, type: .postgresql)

        #expect(hops(connection) == [LocalNetworkHop(role: .database, host: "192.168.1.20")])
    }

    @Test("A loopback host is never named, whatever the probe answers")
    func loopbackIsNeverBlocked() async {
        for host in ["localhost", "127.0.0.1", "[::1]", "::ffff:127.0.0.1"] {
            let connection = DatabaseConnection(name: "Local", host: host, port: 5_432, type: .postgresql)
            let blocked = await LocalNetworkAccessDiagnosis.blockedHop(
                among: hops(connection),
                probe: StubProbe(denied: [host, "::1", "::ffff:127.0.0.1"])
            )
            #expect(blocked == nil, "\(host)")
        }
    }

    @Test("An empty host or a socket path dials nothing")
    func emptyHostIsSkipped() {
        for host in ["", " ", "/tmp/.s.PGSQL.5432"] {
            let connection = DatabaseConnection(name: "Local", host: host, port: 5_432, type: .postgresql)
            #expect(hops(connection).isEmpty, "\(host)")
        }
    }

    @Test("A file database dials no host")
    func fileDatabaseIsSkipped() {
        let connection = DatabaseConnection(name: "File", host: "192.168.1.20", port: 0, type: .sqlite)

        #expect(hops(connection).isEmpty)
    }

    @Test("Behind SSH the server is asked about, never the database it forwards to")
    func sshProbesTheServer() {
        let connection = sshConnection(SSHConfiguration(enabled: true, host: "192.168.1.9", username: "deploy"))

        #expect(hops(connection) == [LocalNetworkHop(role: .sshServer, host: "192.168.1.9")])
    }

    @Test("An SSH alias is asked about by the HostName the tunnel dials")
    func sshAliasResolvesToItsHostName() {
        let connection = sshConnection(SSHConfiguration(enabled: true, host: "db-gateway", username: "deploy"))

        let resolved = hops(connection, sshConfig: "Host db-gateway\n    HostName 192.168.1.9\n")

        #expect(resolved == [LocalNetworkHop(role: .sshServer, host: "192.168.1.9")])
    }

    @Test("With jump hosts only the first one is dialed from this Mac")
    func jumpHostIsTheFirstHop() {
        let jump = SSHJumpHost(host: "10.0.0.5", username: "hop")
        let connection = sshConnection(
            SSHConfiguration(enabled: true, host: "203.0.113.7", username: "deploy", jumpHosts: [jump])
        )

        #expect(hops(connection) == [LocalNetworkHop(role: .sshJumpHost, host: "10.0.0.5")])
    }

    @Test("Behind a SOCKS proxy the proxy is asked about")
    func socksProbesTheProxy() {
        var connection = DatabaseConnection(name: "Proxied", host: "10.20.0.4", port: 5_432, type: .postgresql)
        connection.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "192.168.1.30"))

        #expect(hops(connection) == [LocalNetworkHop(role: .socksProxy, host: "192.168.1.30")])
    }

    @Test("A transport run by a helper process names no hop")
    func helperProcessTransportsAreSkipped() {
        var connection = DatabaseConnection(name: "Cloudflare", host: "192.168.1.20", port: 5_432, type: .postgresql)
        connection.cloudflareTunnelMode = .inline(CloudflareConfiguration(accessHostname: "db.example.com"))

        #expect(hops(connection).isEmpty)
    }

    @Test("A refused hop is named")
    func refusedHopIsNamed() async {
        let hops = [LocalNetworkHop(role: .socksProxy, host: "192.168.1.30")]

        let blocked = await LocalNetworkAccessDiagnosis.blockedHop(among: hops, probe: StubProbe(denied: ["192.168.1.30"]))

        #expect(blocked == LocalNetworkHop(role: .socksProxy, host: "192.168.1.30"))
    }

    @Test("A host list with one reachable server names nothing, since that server may have failed on its own")
    func reachableAlternativeKeepsTheDriverError() async {
        let hops = [
            LocalNetworkHop(role: .database, host: "203.0.113.10"),
            LocalNetworkHop(role: .database, host: "192.168.1.20")
        ]

        #expect(await LocalNetworkAccessDiagnosis.blockedHop(among: hops, probe: StubProbe(denied: ["192.168.1.20"])) == nil)
    }

    @Test("When every host is refused the first in order is named")
    func firstRefusedHopWins() async {
        let hops = [
            LocalNetworkHop(role: .database, host: "192.168.1.20"),
            LocalNetworkHop(role: .database, host: "192.168.1.21")
        ]

        let blocked = await LocalNetworkAccessDiagnosis.blockedHop(
            among: hops,
            probe: StubProbe(denied: ["192.168.1.20", "192.168.1.21"])
        )

        #expect(blocked?.host == "192.168.1.20")
    }

    @Test("A granted hop names nothing")
    func grantedHopIsNotBlocked() async {
        let hops = [LocalNetworkHop(role: .sshServer, host: "192.168.1.9")]

        #expect(await LocalNetworkAccessDiagnosis.blockedHop(among: hops, probe: StubProbe(denied: [])) == nil)
    }

    @Test("Only a failure with no named cause is worth a probe")
    func onlyUnexplainedFailuresAreProbed() {
        #expect(LocalNetworkAccessDiagnosis.canExplain(RouteRefusal(), fields: [:]))
        #expect(!LocalNetworkAccessDiagnosis.canExplain(CancellationError(), fields: [:]))
        #expect(!LocalNetworkAccessDiagnosis.canExplain(PluginError.pluginNotInstalled("SQL Server"), fields: [:]))
        #expect(!LocalNetworkAccessDiagnosis.canExplain(SSLHandshakeError.unknown(serverMessage: "handshake failed"), fields: [:]))
        #expect(!LocalNetworkAccessDiagnosis.canExplain(
            LocalNetworkAccessError(hop: LocalNetworkHop(role: .database, host: "192.168.1.20"), underlying: RouteRefusal()),
            fields: [:]
        ))
    }

    @Test("A failure a browser sign-in fixes keeps its sign-in offer")
    func signInFailuresAreNotProbed() {
        #expect(!LocalNetworkAccessDiagnosis.canExplain(EntraOAuthError.signInRequired, fields: [:]))
    }

    @Test("A setting rejected before any socket opened is never blamed on the permission")
    func preflightFailuresAreNotProbed() {
        #expect(!LocalNetworkAccessDiagnosis.canExplain(SOCKSProxyError.invalidConfiguration, fields: [:]))
        #expect(!LocalNetworkAccessDiagnosis.canExplain(SSHTunnelError.usernameMissing(host: "bastion"), fields: [:]))
        #expect(!LocalNetworkAccessDiagnosis.canExplain(ConnectionTunnelError.remoteFilePathMissing, fields: [:]))
        #expect(LocalNetworkAccessDiagnosis.canExplain(SOCKSProxyError.connectTimedOut(proxyHost: "192.168.1.30", proxyPort: 1_080), fields: [:]))
        #expect(LocalNetworkAccessDiagnosis.canExplain(
            SSHTunnelError.tunnelCreationFailed("Connection to 192.168.1.9:22 failed: No route to host"),
            fields: [:]
        ))
    }
}
