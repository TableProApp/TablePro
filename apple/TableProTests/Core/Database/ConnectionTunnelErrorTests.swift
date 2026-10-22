import Foundation
@testable import TablePro
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
}
