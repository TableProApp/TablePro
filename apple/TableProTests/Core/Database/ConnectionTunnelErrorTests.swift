import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSSHConfig
import Testing

struct ConnectionTunnelErrorTests {
    private func mongo(host: String, useSrv: Bool = false, tunneled: Bool) -> DatabaseConnection {
        var ssh = SSHConfiguration()
        ssh.enabled = tunneled
        ssh.host = "bastion.example.com"
        return DatabaseConnection(
            name: "Atlas", host: host, port: 27_017, type: .mongodb, sshConfig: ssh, mongoUseSrv: useSrv
        )
    }

    @Test("An SRV MongoDB connection through a tunnel is refused, since its servers are dialed around it")
    func srvBehindTunnelIsRefused() {
        #expect(ConnectionTunnelError.refusal(for: mongo(host: "cluster0.ab1cd.mongodb.net", tunneled: true))
            == .srvLookupBehindTunnel)
        #expect(ConnectionTunnelError.refusal(for: mongo(host: "db.internal", useSrv: true, tunneled: true))
            == .srvLookupBehindTunnel)
    }

    @Test("SRV without a tunnel, and a plain host list through one, still connect")
    func otherShapesConnect() {
        #expect(ConnectionTunnelError.refusal(for: mongo(host: "cluster0.ab1cd.mongodb.net", tunneled: false)) == nil)
        #expect(ConnectionTunnelError.refusal(for: mongo(host: "db.internal", tunneled: true)) == nil)
    }

    private func teradata(mode: SSLMode, tunneled: Bool) -> DatabaseConnection {
        var ssh = SSHConfiguration()
        ssh.enabled = tunneled
        ssh.host = "bastion.example.com"
        return DatabaseConnection(
            name: "Warehouse", host: "td.internal", port: 1_025, type: .teradata, sshConfig: ssh,
            sslConfig: SSLConfiguration(mode: mode)
        )
    }

    @Test("Teradata TLS through a tunnel is refused before the tunnel opens", arguments: [
        TableProPluginKit.SSLMode.required, .verifyCa, .verifyIdentity
    ])
    func teradataTLSBehindTunnelIsRefused(mode: TableProPluginKit.SSLMode) {
        let refusal = ConnectionTunnelError.refusal(for: teradata(mode: mode, tunneled: true))
        #expect(refusal == .teradataTLSBehindTunnel)
        #expect(refusal?.failedBeforeDialing == true)
    }

    @Test("Teradata through a tunnel connects with Disabled or Preferred, and with TLS when there is no tunnel")
    func teradataWithoutTLSOrTunnelConnects() {
        #expect(ConnectionTunnelError.refusal(for: teradata(mode: .disabled, tunneled: true)) == nil)
        #expect(ConnectionTunnelError.refusal(for: teradata(mode: .preferred, tunneled: true)) == nil)
        #expect(ConnectionTunnelError.refusal(for: teradata(mode: .required, tunneled: false)) == nil)
    }
}
