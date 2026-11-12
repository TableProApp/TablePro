//
//  DatabaseManagerTunnelTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSSHConfig
import TableProTestSupport
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

    @Test("A tunneled connection keeps its credential profile, so it signs in with the profile's credentials")
    func tunnelPreservesCredentialProfile() {
        let profileId = UUID()
        var connection = DatabaseConnection(name: "tunneled", host: "db.internal", port: 3_306, type: .mysql)
        connection.credentialMode = .profile(id: profileId)

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 61_235)

        #expect(tunneled.credentialMode.profileId == profileId)
        #expect(ConnectionCredentialResolver.credentialOwner(for: tunneled) == profileId)
    }

    @Test("A tunneled DuckDB Remote row dials the forward through its own Host and Port fields")
    func tunnelRewritesServerEndpointFields() {
        let connection = DatabaseConnection(
            name: "quack",
            host: "localhost",
            port: 9_494,
            type: .duckdb,
            additionalFields: [
                "duckdbMode": "remote",
                "duckdbHost": "quack.internal",
                "duckdbPort": "9500",
                "duckdbAlias": "remotedb"
            ]
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 61_234)

        #expect(tunneled.additionalFields["duckdbHost"] == "127.0.0.1")
        #expect(tunneled.additionalFields["duckdbPort"] == "61234")
        #expect(tunneled.additionalFields["duckdbAlias"] == "remotedb")
        #expect(tunneled.preTunnelHost == "quack.internal")
        #expect(tunneled.preTunnelPort == 9_500)
        #expect(tunneled.host == "127.0.0.1")
        #expect(tunneled.port == 61_234)
    }

    @Test("A server port the driver would refuse opens no tunnel, so nothing dials it and the driver reports it")
    func unusableServerPortOpensNoTunnel() {
        var ssh = SSHConfiguration()
        ssh.enabled = true
        ssh.host = "bastion.example.com"
        ssh.username = "deploy"
        for typed in ["94x4", "0", "70000", "2147483648"] {
            let connection = DatabaseConnection(
                name: "quack",
                host: "localhost",
                port: 9_494,
                type: .duckdb,
                sshConfig: ssh,
                additionalFields: ["duckdbMode": "remote", "duckdbHost": "quack.internal", "duckdbPort": typed]
            )

            #expect(!connection.serverEndpointPortIsUsable, "\(typed)")
            #expect(connection.enabledTunnelKinds.isEmpty, "\(typed) would open a tunnel")
        }
    }

    @Test("An empty server port is the field's default, so the forward replaces it")
    func tunnelRewritesEmptyServerPort() {
        let connection = DatabaseConnection(
            name: "quack",
            host: "localhost",
            port: 9_494,
            type: .duckdb,
            additionalFields: ["duckdbMode": "remote", "duckdbHost": "quack.internal", "duckdbPort": ""]
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 61_234)

        #expect(connection.serverEndpointPortIsUsable)
        #expect(tunneled.additionalFields["duckdbPort"] == "61234")
    }

    @Test("A tunneled network row keeps every plugin field it carries")
    func tunnelLeavesNetworkFieldsAlone() {
        let connection = DatabaseConnection(
            name: "pg",
            host: "db.internal",
            port: 5_432,
            type: .postgresql,
            additionalFields: ["duckdbHost": "stale.example"]
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 61_234)

        #expect(tunneled.additionalFields["duckdbHost"] == "stale.example")
        #expect(tunneled.preTunnelHost == "db.internal")
    }

    @Test("A DuckDB Local File row with a stored SSH tunnel connects without opening it")
    func duckdbLocalSkipsStoredTunnel() async throws {
        var connection = DatabaseConnection(
            name: "file",
            type: .duckdb,
            additionalFields: ["duckdbMode": "local", "duckdbFilePath": "/tmp/tablepro-tests.duckdb"]
        )
        connection.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.invalid"))

        let effective = try await DatabaseManager.shared.buildEffectiveConnection(
            for: connection,
            deadline: ConnectionDeadline(configuredSeconds: 5)
        )

        #expect(effective.host == connection.host)
        #expect(effective.preTunnelHost == nil)
        #expect(effective.additionalFields["duckdbFilePath"] == "/tmp/tablepro-tests.duckdb")
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

    @Test("A tunneled https:// node with SSL Mode left on Disabled verifies the server, as its direct dial does")
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
        #expect(tunneled.sslConfig.mode == .verifyIdentity)
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

    @Test("A TCP forward keeps the SSL mode")
    func tcpForwardKeepsTLS() {
        let connection = DatabaseConnection(
            name: "pg",
            host: "db.internal",
            port: 5_432,
            type: .postgresql,
            sslConfig: SSLConfiguration(mode: .verifyIdentity)
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.sslConfig.mode == .verifyIdentity)
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

    @Test("Verify Identity through an SSH TCP forward keeps the mode, the CA and the client pair, and names the server")
    func tcpForwardKeepsVerificationAndClientIdentity() {
        var connection = DatabaseConnection(
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
        connection.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "ssh.example.com"))
        #expect(connection.dialsTunnelTCPForward)

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

        #expect(tunneled.sslConfig.mode == .verifyIdentity)
        #expect(tunneled.sslConfig.caCertificatePath == "/certs/ca.pem")
        #expect(tunneled.sslConfig.clientCertificatePath == "/certs/client.pem")
        #expect(tunneled.sslConfig.clientKeyPath == "/certs/client.key")
        #expect(tunneled.preTunnelHost == "db.internal")
        #expect(tunneled.tunneledServerName == "db.internal")
    }

    @Test("The Cloud SQL Auth Proxy's plaintext listener gets no TLS, whatever mode the connection asks for")
    func cloudSQLProxyDisablesTLS() {
        let connection = DatabaseConnection(
            name: "cloudsql",
            host: "10.0.0.5",
            port: 5_432,
            type: .postgresql,
            sslConfig: SSLConfiguration(
                mode: .verifyIdentity,
                caCertificatePath: "/certs/ca.pem",
                clientCertificatePath: "/certs/client.pem",
                clientKeyPath: "/certs/client.key"
            )
        )

        let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000, securesTransport: true)

        #expect(tunneled.sslConfig.mode == .disabled)
        #expect(tunneled.sslConfig.caCertificatePath.isEmpty)
        #expect(tunneled.sslConfig.clientCertificatePath.isEmpty)
        #expect(tunneled.sslConfig.clientKeyPath.isEmpty)
        #expect(tunneled.tunnelSecuresTransport)
    }

    @Test("Only the TCP forwards carry TLS to the server: SSH, Cloudflare, SOCKS and a tunnel command")
    func tunnelKindsThatDialATCPForward() {
        let expected: [ConnectionTunnelKind: Bool] = [
            .ssh: true, .cloudflare: true, .cloudSQLProxy: false, .socksProxy: true, .tunnelCommand: true
        ]
        for (kind, connection) in tunnelFixtures() {
            #expect(connection.dialsTunnelTCPForward == expected[kind], "\(kind)")
        }

        var socketForward = tunnelFixtures()[0].1
        socketForward.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"
        #expect(!socketForward.dialsTunnelTCPForward)
        #expect(!DatabaseConnection(name: "direct", type: .postgresql).dialsTunnelTCPForward)
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

    @Test("A server name saved or imported on a direct connection never reaches the driver")
    func storedPreTunnelEndpointIsDroppedOnDirectConnect() async throws {
        let direct = DatabaseConnection(
            name: "local",
            host: "127.0.0.1",
            port: 5_432,
            type: .postgresql,
            sslConfig: SSLConfiguration(mode: .verifyIdentity),
            additionalFields: [
                DatabaseConnection.preTunnelHostKey: "db.attacker.example",
                DatabaseConnection.preTunnelPortKey: "5432"
            ]
        )

        let effective = try await DatabaseManager.shared.buildEffectiveConnection(
            for: direct,
            deadline: ConnectionDeadline(configuredSeconds: 60)
        )

        #expect(effective.host == "127.0.0.1")
        #expect(effective.preTunnelHost == nil)
        #expect(effective.preTunnelPort == nil)
        #expect(effective.tunneledServerName == nil)
    }

    @Test("A remote SQLite agent backend saved or imported on a plain row never reaches the driver")
    func storedRemoteSQLiteBackendIsDropped() async throws {
        let planted = DatabaseConnection(
            name: "notes",
            host: "attacker.example",
            port: 4_444,
            database: "/tmp/notes.db",
            type: .sqlite,
            additionalFields: [
                RemoteSQLiteWire.backendFieldKey: RemoteSQLiteWire.agentBackendValue,
                RemoteSQLiteWire.tokenFieldKey: "planted"
            ]
        )

        let effective = try await DatabaseManager.shared.buildEffectiveConnection(
            for: planted,
            deadline: ConnectionDeadline(configuredSeconds: 60)
        )

        #expect(effective.additionalFields[RemoteSQLiteWire.backendFieldKey] == nil)
        #expect(effective.additionalFields[RemoteSQLiteWire.tokenFieldKey] == nil)
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

    @Test("Every tunnel drops the local MySQL socket, so the driver dials the forward")
    func localSocketIsStrippedFromTunneledFields() {
        for (kind, fixture) in tunnelFixtures() {
            var connection = fixture
            connection.type = .mysql
            connection.host = "db.internal"
            connection.port = 3_306
            connection.additionalFields[MySQLLocalSocket.fieldKey] = "/tmp/mysql.sock"

            let tunneled = DatabaseManager.shared.tunneledConnection(from: connection, localPort: 62_000)

            #expect(tunneled.host == "127.0.0.1", "\(kind)")
            #expect(tunneled.port == 62_000, "\(kind)")
            #expect(tunneled.additionalFields[MySQLLocalSocket.fieldKey] == nil, "\(kind)")
        }
    }

    @Test("Exhausted tunnel recovery keeps the session and reports it lost, not a failed connect")
    func exhaustedRecoveryReportsALostSession() async throws {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let clock = ManualClock()
        let manager = DatabaseManager(recoveryClock: clock)
        var connection = TestFixtures.makeConnection(name: "dead tunnel")
        connection.type = DatabaseType(rawValue: FakeMSSQLPlugin.databaseTypeId)
        let driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        manager.injectSession(session, for: connection.id)
        FakeMSSQLPlugin.failConnect(for: connection.id, with: TestTunnelFailure(value: 1))
        defer {
            FakeMSSQLPlugin.clearConnectFailure(for: connection.id)
            manager.removeSession(for: connection.id)
        }

        manager.recoverDeadTunnel(connectionId: connection.id, kind: "SSH", disconnectedMessage: "The SSH tunnel closed.")
        let loop = try #require(manager.recoveryLoops[connection.id]?.task)
        for _ in 1...ConnectionRecoveryProgress.maxAttempts {
            await clock.waitUntilSleeping()
            clock.advance(by: .seconds(DatabaseManager.maxRecoveryDelay))
        }
        await loop.value

        let current = try #require(manager.session(for: connection.id))
        #expect(current.driver === driver)
        #expect(current.recovery == nil)
        let reason = manager.disconnectReason(for: connection.id)
        guard case .sessionLost(let info) = reason else {
            Issue.record("An exhausted tunnel recovery is a lost session, not a failed connect: \(String(describing: reason))")
            return
        }
        #expect(info.message == "The SSH tunnel closed.")
        #expect(info.failureReason?.contains("10") == true)
        #expect(current.liveness == .unreachable(info))

        let snapshot = ConnectionSessionSnapshot(exists: true, hasDriver: true, endReason: reason, liveness: current.liveness)
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connected,
            session: snapshot,
            ownsAttempt: false
        )
        #expect(phase == .unavailable(.disconnected(info)))
    }
}

extension GlobalStateSuites {
    // Writes the shared SSH profile store across suspensions.
    @MainActor
    struct PinnedSSHRouteTests {
        @Test("A pinned route is refused once the linked profile moves, and followed while it stays")
        func pinnedRouteRefusesAMovedProfile() async throws {
            let profiles = SSHProfileStorage.shared
            let saved = profiles.loadProfiles()
            let profile = SSHProfile(name: "Jump", host: "bastion-b.example", port: 22, username: "ops", authMethod: .password)
            #expect(profiles.saveProfilesWithoutSync(saved + [profile]))
            defer { profiles.saveProfilesWithoutSync(saved) }
            var dialed = profile.toSSHConfiguration()
            dialed.host = "bastion-a.example"
            var connection = DatabaseConnection(
                name: "file",
                type: .duckdb,
                additionalFields: ["duckdbMode": "local", "duckdbFilePath": "/tmp/tablepro-tests.duckdb"]
            )
            connection.sshTunnelMode = .profile(id: profile.id, snapshot: dialed)

            await #expect(throws: ConnectionTunnelError.sshProfileMoved) {
                try await DatabaseManager.shared.buildEffectiveConnection(
                    for: connection,
                    pinnedSSHRoute: connection.destinationTunnel,
                    deadline: ConnectionDeadline(configuredSeconds: 5)
                )
            }

            let current = profiles.refreshingLinkedProfile(connection)
            let effective = try await DatabaseManager.shared.buildEffectiveConnection(
                for: connection,
                pinnedSSHRoute: current.destinationTunnel,
                deadline: ConnectionDeadline(configuredSeconds: 5)
            )
            #expect(effective.additionalFields["duckdbFilePath"] == "/tmp/tablepro-tests.duckdb")
        }
    }
}
