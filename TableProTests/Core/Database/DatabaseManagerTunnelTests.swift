//
//  DatabaseManagerTunnelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DatabaseManagerTunnelTests {
    private struct TestTunnelFailure: Error, Equatable {
        let value: Int
    }

    private func tunnelFixtures() -> [(ConnectionTunnelKind, DatabaseConnection)] {
        var ssh = DatabaseConnection(name: "SSH", type: .postgresql)
        ssh.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "ssh.example.com"))

        var cloudflare = DatabaseConnection(name: "Cloudflare", type: .postgresql)
        cloudflare.cloudflareTunnelMode = .inline(CloudflareConfiguration(accessHostname: "db.example.com"))

        var cloudSQL = DatabaseConnection(name: "Cloud SQL", type: .postgresql)
        cloudSQL.cloudSQLProxyMode = .inline(CloudSQLProxyConfiguration(instanceConnectionName: "p:r:i"))

        var socks = DatabaseConnection(name: "SOCKS", type: .postgresql)
        socks.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "proxy.example.com"))

        var command = DatabaseConnection(name: "Command", type: .postgresql)
        command.tunnelCommandMode = .inline(
            TunnelCommandConfiguration(method: .kubectl, kubernetesResource: "service/pg")
        )

        return [
            (.ssh, ssh),
            (.cloudflare, cloudflare),
            (.cloudSQLProxy, cloudSQL),
            (.socksProxy, socks),
            (.tunnelCommand, command)
        ]
    }

    @Test("Tunneled connection rewrites the endpoint and keeps the password source")
    func tunnelPreservesPasswordSource() {
        var connection = DatabaseConnection(
            name: "tunneled",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )
        connection.passwordSource = .env(variable: "DB_PASS")

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 61_234)

        #expect(tunneled.host == "127.0.0.1")
        #expect(tunneled.port == 61_234)
        #expect(tunneled.passwordSource == .env(variable: "DB_PASS"))
    }

    @Test("Every tunnel rewrite preserves inherited disabled and finite timeout states")
    func tunnelPreservesTimeoutOverrides() {
        let overrides: [(connect: Int?, query: Int?)] = [
            (nil, nil),
            (12, 0),
            (600, 45)
        ]

        for (kind, template) in tunnelFixtures() {
            #expect(template.activeTunnelKind == kind)
            for override in overrides {
                var connection = template
                connection.connectTimeoutSeconds = override.connect
                connection.queryTimeoutSeconds = override.query

                let tunneled = DatabaseManager.shared.tunneledConnection(
                    from: connection,
                    localPort: 61_234
                )

                #expect(tunneled.connectTimeoutSeconds == override.connect)
                #expect(tunneled.queryTimeoutSeconds == override.query)
            }
        }
    }

    @Test("Tunnel attribution replaces a driver symptom before teardown")
    func tunnelAttributionPrecedesTeardown() async {
        var events: [String] = []
        let reported = await DatabaseManager.preferredTunnelFailure(
            replacing: TestTunnelFailure(value: 1)
        ) {
            events.append("attribution")
            return TestTunnelFailure(value: 2)
        }
        events.append("teardown")

        #expect((reported as? TestTunnelFailure) == TestTunnelFailure(value: 2))
        #expect(events == ["attribution", "teardown"])
    }

    @Test("Tunnel attribution never replaces cancellation")
    func tunnelAttributionPreservesCancellation() async {
        var consumed = false
        let reported = await DatabaseManager.preferredTunnelFailure(replacing: CancellationError()) {
            consumed = true
            return TestTunnelFailure(value: 2)
        }

        #expect(reported is CancellationError)
        #expect(!consumed)
    }

    @Test("Every first-forward transport has an attributed failure manager")
    func firstForwardTransportManagers() {
        var ssh = DatabaseConnection(name: "SSH", type: .postgresql)
        ssh.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "ssh.example.com"))

        var socks = DatabaseConnection(name: "SOCKS", type: .postgresql)
        socks.socksProxyMode = .inline(SOCKSProxyConfiguration(host: "proxy.example.com"))

        var remoteConfiguration = SSHConfiguration()
        remoteConfiguration.enabled = true
        remoteConfiguration.host = "ssh.example.com"
        remoteConfiguration.username = "deploy"
        remoteConfiguration.remoteFilePath = "/srv/app.db"
        remoteConfiguration.remoteFileAccess = .onServer
        let remoteSQLite = DatabaseConnection(
            name: "Remote SQLite",
            type: .sqlite,
            sshTunnelMode: .inline(remoteConfiguration)
        )

        #expect(DatabaseManager.shared.activeTunnelManager(for: ssh) is SSHTunnelManager)
        #expect(DatabaseManager.shared.activeTunnelManager(for: socks) is SOCKSProxyManager)
        #expect(DatabaseManager.shared.activeTunnelManager(for: remoteSQLite) is RemoteSQLiteTransportManager)
    }

    @Test("Tunneled Redis keeps the database index the connection names")
    func tunnelKeepsRedisDatabaseIndex() {
        let connection = DatabaseConnection(
            name: "redis",
            host: "cache.internal",
            port: 6_379,
            type: .redis,
            redisDatabase: 4,
            additionalFields: ["redisMode": "standalone"]
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.additionalFields["redisDatabase"] == "4")
        #expect(tunneled.redisDatabaseIndex == 4)
    }

    @Test("Tunneled Redis Cluster opens database 0 after the tunnel forces Standalone")
    func tunnelKeepsClusterOnDatabaseZero() {
        let connection = DatabaseConnection(
            name: "cluster",
            host: "node.internal",
            port: 7_000,
            type: .redis,
            additionalFields: ["redisMode": "cluster", "redisDatabase": "4"]
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.additionalFields["redisMode"] == "standalone")
        #expect(tunneled.redisDatabaseIndex == 0)
    }

    @Test("Tunneled MongoDB collapses the seed list and forces a direct connection")
    func tunnelForcesMongoDirectConnection() {
        let connection = DatabaseConnection(
            name: "mongo",
            host: "primary.internal",
            port: 27_017,
            type: .mongodb,
            additionalFields: ["mongoHosts": "primary.internal:27017,secondary.internal:27017"]
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.host == "127.0.0.1")
        #expect(tunneled.port == 62_000)
        #expect(tunneled.additionalFields["mongoHosts"] == nil)
        #expect(tunneled.additionalFields["mongoParam_directConnection"] == "true")
    }

    @Test("Tunneled MongoDB leaves SRV connections untouched")
    func tunnelLeavesMongoSrvUntouched() {
        let connection = DatabaseConnection(
            name: "atlas",
            host: "cluster0.example.com",
            port: 27_017,
            type: .mongodb,
            additionalFields: ["mongoHosts": "cluster0.example.com", "mongoUseSrv": "true"]
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.additionalFields["mongoHosts"] == "cluster0.example.com")
        #expect(tunneled.additionalFields["mongoParam_directConnection"] == nil)
    }

    @Test("A tunneled https:// node keeps TLS with SSL Mode left on Disabled")
    func tunnelKeepsTLSForHTTPSNode() {
        let connection = DatabaseConnection(
            name: "es",
            host: "localhost",
            port: 9_200,
            type: .elasticsearch,
            additionalFields: ["esHosts": "https://es1.internal:9200,https://es2.internal:9200"]
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.additionalFields["esHosts"] == nil)
        #expect(tunneled.preTunnelHost == "es1.internal")
        #expect(tunneled.sslConfig.mode == .required)
    }

    @Test("Tunneled non-MongoDB connection gets no direct-connection override")
    func tunnelLeavesNonMongoUntouched() {
        let connection = DatabaseConnection(
            name: "pg",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.additionalFields["mongoParam_directConnection"] == nil)
    }

    @Test("A socket forward drops TLS, which the destination cannot negotiate")
    func socketForwardDisablesTLS() {
        var connection = DatabaseConnection(
            name: "socket",
            host: "db.internal",
            port: 5_432,
            type: .postgresql,
            sslConfig: SSLConfiguration(mode: .required)
        )
        connection.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"

        let tunneled = DatabaseManager.shared.tunneledConnection(
            from: connection,
            localPort: 62_000,
            forwardsToUnixSocket: true
        )

        #expect(tunneled.sslConfig.mode == .disabled)
    }

    @Test("A TCP forward keeps encryption on")
    func tcpForwardKeepsTLS() {
        let connection = DatabaseConnection(
            name: "pg",
            host: "db.internal",
            port: 5_432,
            type: .postgresql,
            sslConfig: SSLConfiguration(mode: .verifyIdentity)
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.sslConfig.mode == .required)
    }

    @Test("A TCP forward keeps the client certificate and key")
    func tcpForwardKeepsClientIdentity() {
        let connection = DatabaseConnection(
            name: "pg",
            host: "db.internal",
            port: 5_432,
            type: .postgresql,
            sslConfig: SSLConfiguration(
                mode: .required,
                clientCertificatePath: "/certs/client.pem",
                clientKeyPath: "/certs/client.key"
            )
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.sslConfig.mode == .required)
        #expect(tunneled.sslConfig.clientCertificatePath == "/certs/client.pem")
        #expect(tunneled.sslConfig.clientKeyPath == "/certs/client.key")
    }

    @Test("A TCP forward relaxes Verify Identity and still keeps the client certificate and key")
    func tcpForwardRelaxesVerificationAndKeepsClientIdentity() {
        let connection = DatabaseConnection(
            name: "mysql",
            host: "db.internal",
            port: 3_306,
            type: .mysql,
            sslConfig: SSLConfiguration(
                mode: .verifyIdentity,
                caCertificatePath: "/certs/ca.pem",
                clientCertificatePath: "/certs/client.pem",
                clientKeyPath: "/certs/client.key"
            )
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.sslConfig.mode == .required)
        #expect(tunneled.sslConfig.clientCertificatePath == "/certs/client.pem")
        #expect(tunneled.sslConfig.clientKeyPath == "/certs/client.key")
    }

    @Test("A socket forward clears the client certificate and key along with TLS")
    func socketForwardClearsClientIdentity() {
        var connection = DatabaseConnection(
            name: "socket",
            host: "db.internal",
            port: 5_432,
            type: .postgresql,
            sslConfig: SSLConfiguration(
                mode: .required,
                clientCertificatePath: "/certs/client.pem",
                clientKeyPath: "/certs/client.key"
            )
        )
        connection.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"

        let tunneled = DatabaseManager.shared.tunneledConnection(
            from: connection,
            localPort: 62_000,
            forwardsToUnixSocket: true
        )

        #expect(tunneled.sslConfig.mode == .disabled)
        #expect(tunneled.sslConfig.clientCertificatePath.isEmpty)
        #expect(tunneled.sslConfig.clientKeyPath.isEmpty)
    }

    @Test("The pre-tunnel endpoint is recorded for every tunneled connection")
    func tunnelRecordsPreTunnelEndpoint() {
        let connection = DatabaseConnection(
            name: "rds",
            host: "mydb.abc123.us-east-1.rds.amazonaws.com",
            port: 5_432,
            type: .postgresql,
            additionalFields: ["awsAuth": "profile"]
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.preTunnelHost == "mydb.abc123.us-east-1.rds.amazonaws.com")
        #expect(tunneled.preTunnelPort == 5_432)
    }

    @Test("A connection that is not tunneled has no pre-tunnel endpoint")
    func directConnectionHasNoPreTunnelEndpoint() {
        let connection = DatabaseConnection(
            name: "rds",
            host: "mydb.abc123.us-east-1.rds.amazonaws.com",
            port: 5_432,
            type: .postgresql
        )

        #expect(connection.preTunnelHost == nil)
        #expect(connection.preTunnelPort == nil)
    }

    @Test("The socket path never reaches the driver")
    func socketPathIsStrippedFromDriverFields() {
        var connection = DatabaseConnection(
            name: "socket",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )
        connection.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"

        let tunneled = DatabaseManager.shared.tunneledConnection(
            from: connection,
            localPort: 62_000,
            forwardsToUnixSocket: true
        )

        #expect(tunneled.host == "127.0.0.1")
        #expect(tunneled.port == 62_000)
        #expect(tunneled.additionalFields[DatabaseConnection.sshForwardUnixSocketPathKey] == nil)
    }

    @Test("Exhausted tunnel recovery removes the session instead of leaving a spinner")
    func exhaustedRecoveryRemovesTheSession() {
        let connection = DatabaseConnection(
            name: "dead tunnel",
            host: "db.internal",
            port: 5_432,
            type: .postgresql
        )
        var session = ConnectionSession(connection: connection)
        session.status = .connecting
        DatabaseManager.shared.injectSession(session, for: connection.id)

        DatabaseManager.shared.failTunnelRecovery(
            connectionId: connection.id,
            disconnectedMessage: "The SSH tunnel closed.",
            attempts: 10
        )

        #expect(DatabaseManager.shared.activeSessions[connection.id] == nil)

        let reason = DatabaseManager.shared.disconnectReason(for: connection.id)
        guard case .sessionLost(let info) = reason else {
            Issue.record("An exhausted tunnel recovery is a lost session, not a failed connect: \(String(describing: reason))")
            return
        }
        #expect(info.message == "The SSH tunnel closed.")
        #expect(info.failureReason?.contains("10") == true)

        let snapshot = ConnectionSessionSnapshot(exists: false, hasDriver: false, endReason: reason)
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connecting,
            session: snapshot,
            ownsAttempt: false
        )
        #expect(phase != .connecting)
    }
}
