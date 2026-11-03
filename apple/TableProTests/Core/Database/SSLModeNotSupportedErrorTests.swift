import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSSHConfig
import Testing

private final class PlainTCPNetworkPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Plain TCP"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A network driver that speaks plain TCP only"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Dameng"
    static let databaseDisplayName = "Dameng"
    static let iconName = "cylinder"
    static let defaultPort = 5_236
    static let supportedSSLModes: [SSLMode] = [.disabled, .preferred]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class PlainFilePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Plain File"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A file driver with no transport"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "SQLite"
    static let databaseDisplayName = "SQLite"
    static let iconName = "cylinder"
    static let defaultPort = 0
    static let connectionMode: ConnectionMode = .fileBased
    static let supportedSSLModes: [SSLMode] = [.disabled]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class EveryModeNetworkPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Every Mode"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A network driver that declares no TLS modes of its own"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "PostgreSQL"
    static let databaseDisplayName = "PostgreSQL"
    static let iconName = "cylinder"
    static let defaultPort = 5_432

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class TunnelPlaintextPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Tunnel Plaintext"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A network driver whose TLS port a tunnel does not forward"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "Teradata"
    static let databaseDisplayName = "Teradata"
    static let iconName = "cylinder"
    static let defaultPort = 1_025
    static let sslModesThroughTunnel: [SSLMode] = [.disabled, .preferred]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class TunnelVerifyingPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Tunnel Verifying"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "A network driver that checks the server behind a tunnel"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "PostgreSQL"
    static let databaseDisplayName = "PostgreSQL"
    static let iconName = "cylinder"
    static let defaultPort = 5_432
    static let sslModesThroughTunnel: [SSLMode] = SSLMode.allCases

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

struct SSLModeNotSupportedErrorTests {
    private func connection(_ type: DatabaseType, mode: SSLMode) -> DatabaseConnection {
        DatabaseConnection(name: "Ledger", host: "db.example.com", type: type, sslConfig: SSLConfiguration(mode: mode))
    }

    private func overSSH(_ type: DatabaseType, mode: SSLMode) -> DatabaseConnection {
        var tunneled = connection(type, mode: mode)
        tunneled.sshTunnelMode = .inline(SSHConfiguration(enabled: true, host: "bastion.example.com"))
        return tunneled
    }

    @Test("A mode the driver cannot keep is refused before anything dials", arguments: [
        TableProPluginKit.SSLMode.required, .verifyCa, .verifyIdentity
    ])
    func unsupportedModeIsRefused(mode: TableProPluginKit.SSLMode) throws {
        let refusal = try #require(
            SSLModeNotSupportedError.refusal(for: connection(.dameng, mode: mode), pluginType: PlainTCPNetworkPlugin.self)
        )

        #expect(refusal.mode == mode)
        #expect(refusal.supportedModes == [.disabled, .preferred])
        #expect(refusal.failedBeforeDialing)
        #expect(refusal.errorDescription?.contains("Dameng") == true)
        #expect(refusal.errorDescription?.contains(mode.displayLabel) == true)
    }

    @Test("A mode the driver lists connects", arguments: [TableProPluginKit.SSLMode.disabled, .preferred])
    func supportedModeConnects(mode: TableProPluginKit.SSLMode) {
        #expect(SSLModeNotSupportedError.refusal(
            for: connection(.dameng, mode: mode), pluginType: PlainTCPNetworkPlugin.self
        ) == nil)
    }

    @Test("A file driver is never refused for a stray mode")
    func fileDriverIsNotGated() {
        #expect(SSLModeNotSupportedError.refusal(
            for: connection(.sqlite, mode: .verifyIdentity), pluginType: PlainFilePlugin.self
        ) == nil)
    }

    @Test("A driver that declares nothing keeps every mode", arguments: TableProPluginKit.SSLMode.allCases)
    func defaultDriverKeepsEveryMode(mode: TableProPluginKit.SSLMode) {
        #expect(SSLModeNotSupportedError.refusal(
            for: connection(.postgresql, mode: mode), pluginType: EveryModeNetworkPlugin.self
        ) == nil)
    }

    @Test("A driver that declares nothing refuses a verify mode over SSH before the tunnel opens, and keeps it direct")
    func undeclaredDriverRefusesVerifyThroughTunnel() throws {
        let refusal = try #require(SSLModeNotSupportedError.refusal(
            for: overSSH(.postgresql, mode: .verifyIdentity), pluginType: EveryModeNetworkPlugin.self
        ))

        #expect(refusal.reason == .unsupportedThroughTunnel)
        #expect(refusal.mode == .verifyIdentity)
        #expect(refusal.supportedModes == [.disabled, .preferred, .required])
        #expect(refusal.driverMayAddMode)
        #expect(refusal.failedBeforeDialing)
        #expect(SSLModeNotSupportedError.refusal(
            for: connection(.postgresql, mode: .verifyIdentity), pluginType: EveryModeNetworkPlugin.self
        ) == nil)
    }

    @Test("Teradata TLS through a tunnel is refused before the tunnel opens", arguments: [
        TableProPluginKit.SSLMode.required, .verifyCa, .verifyIdentity
    ])
    func teradataTLSThroughTunnelIsRefused(mode: TableProPluginKit.SSLMode) throws {
        let refusal = try #require(SSLModeNotSupportedError.refusal(
            for: overSSH(.teradata, mode: mode), pluginType: TunnelPlaintextPlugin.self
        ))

        #expect(refusal.reason == .unsupportedThroughTunnel)
        #expect(refusal.supportedModes == [.disabled, .preferred])
        #expect(!refusal.driverMayAddMode)
        #expect(refusal.errorDescription?.contains("Teradata") == true)
    }

    @Test("Teradata through a tunnel connects with Disabled or Preferred, and with TLS when there is no tunnel")
    func teradataWithoutTLSOrTunnelConnects() {
        for mode in [SSLMode.disabled, .preferred] {
            #expect(SSLModeNotSupportedError.refusal(
                for: overSSH(.teradata, mode: mode), pluginType: TunnelPlaintextPlugin.self
            ) == nil)
        }
        #expect(SSLModeNotSupportedError.refusal(
            for: connection(.teradata, mode: .required), pluginType: TunnelPlaintextPlugin.self
        ) == nil)
    }

    @Test("A driver that checks the server behind a tunnel keeps every mode over SSH")
    func verifyingDriverKeepsModesThroughTunnel() {
        for mode in SSLMode.allCases {
            #expect(SSLModeNotSupportedError.refusal(
                for: overSSH(.postgresql, mode: mode), pluginType: TunnelVerifyingPlugin.self
            ) == nil)
        }
    }

    @Test("Verify CA through Cloudflare with a blank host is refused, since there is no server to check against")
    func blankHostThroughCloudflareIsRefused() throws {
        var blank = DatabaseConnection(name: "Edge", host: "", type: .postgresql, sslConfig: SSLConfiguration(mode: .verifyCa))
        blank.cloudflareTunnelMode = .inline(CloudflareConfiguration(accessHostname: "db.example.com"))

        let refusal = try #require(SSLModeNotSupportedError.refusal(for: blank, pluginType: TunnelVerifyingPlugin.self))

        #expect(refusal.reason == .tunnelNamesNoServer)
        #expect(refusal.supportedModes == [.disabled, .preferred, .required])

        var named = blank
        named.host = "db.internal"
        #expect(SSLModeNotSupportedError.refusal(for: named, pluginType: TunnelVerifyingPlugin.self) == nil)
    }

    @Test("A forward that runs without TLS, the Cloud SQL Auth Proxy and an SSH socket forward, refuses no mode")
    func plaintextForwardsAreNotRefused() {
        var proxied = connection(.postgresql, mode: .verifyIdentity)
        proxied.cloudSQLProxyMode = .inline(CloudSQLProxyConfiguration(instanceConnectionName: "p:r:i"))
        #expect(SSLModeNotSupportedError.refusal(for: proxied, pluginType: EveryModeNetworkPlugin.self) == nil)

        var socketForward = overSSH(.postgresql, mode: .verifyIdentity)
        socketForward.sshForwardUnixSocketPath = "/var/run/postgresql/.s.PGSQL.5432"
        #expect(SSLModeNotSupportedError.refusal(for: socketForward, pluginType: EveryModeNetworkPlugin.self) == nil)
    }
}
