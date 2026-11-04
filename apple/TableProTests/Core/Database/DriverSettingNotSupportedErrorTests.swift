import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSSHConfig
import Testing

/// A DuckDB driver from before Remote mode had an SSL Mode: it declares the Remote fields it read then.
private final class DuckDBDriverBeforeSSLMode: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "DuckDB Driver"
    static let pluginVersion = "1.1.0"
    static let pluginDescription = "DuckDB as it shipped before the SSL Mode field"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DuckDB"
    static let databaseDisplayName = "DuckDB"
    static let iconName = "duckdb-icon"
    static let defaultPort = 9_494
    static let connectionMode: ConnectionMode = .apiOnly
    static let additionalConnectionFields: [ConnectionField] = ["duckdbMode", "duckdbHost", "duckdbPort", "duckdbToken"]
        .map { ConnectionField(id: $0, label: $0) }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

/// The current driver, which declares every field the curated entry lists.
private final class DuckDBDriverWithSSLMode: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "DuckDB Driver"
    static let pluginVersion = "1.2.0"
    static let pluginDescription = "DuckDB with the SSL Mode field"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "DuckDB"
    static let databaseDisplayName = "DuckDB"
    static let iconName = "duckdb-icon"
    static let defaultPort = 9_494
    static let connectionMode: ConnectionMode = .apiOnly
    static let additionalConnectionFields: [ConnectionField] = PluginMetadataRegistry.shared
        .curatedSnapshot(for: .duckdb)?.connection.additionalConnectionFields ?? []

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

struct DriverSettingNotSupportedErrorTests {
    private func remote(sslMode: String?, mode: String = "remote", ssh: SSHConfiguration = SSHConfiguration()) -> DatabaseConnection {
        var fields = ["duckdbMode": mode, "duckdbHost": "quack.internal", "duckdbPort": "9494"]
        fields["duckdbSSLMode"] = sslMode
        return DatabaseConnection(
            name: "quack", host: "localhost", port: 9_494, type: .duckdb, sshConfig: ssh, additionalFields: fields
        )
    }

    @Test("A driver from before SSL Mode is refused for every mode that is not Automatic, naming the setting")
    func olderDriverRefusesAChosenMode() throws {
        for mode in ["disabled", "required", "verifyIdentity", "verifyFingerprint"] {
            let refusal = try #require(
                DriverSettingNotSupportedError.refusal(for: remote(sslMode: mode), pluginType: DuckDBDriverBeforeSSLMode.self),
                "\(mode) would connect as Automatic"
            )
            #expect(refusal.setting == .field(label: String(localized: "SSL Mode")))
            #expect(refusal.errorDescription?.contains("DuckDB") == true)
        }
    }

    @Test("Automatic, or no stored mode, is what the older driver does anyway, so it connects")
    func olderDriverKeepsAutomatic() {
        for mode in [nil, "", "automatic"] {
            #expect(
                DriverSettingNotSupportedError.refusal(for: remote(sslMode: mode), pluginType: DuckDBDriverBeforeSSLMode.self)
                    == nil,
                "\(mode ?? "nil")"
            )
        }
    }

    @Test("A Local File row keeps whatever its hidden Remote SSL Mode holds, since it dials nothing")
    func hiddenFieldIsNotChecked() {
        let local = remote(sslMode: "required", mode: "local")
        #expect(DriverSettingNotSupportedError.refusal(for: local, pluginType: DuckDBDriverBeforeSSLMode.self) == nil)
    }

    @Test("A driver from before SSL Mode is refused any tunnel, Automatic included, since it would send the token in plain HTTP")
    func olderDriverRefusesATunnel() throws {
        var ssh = SSHConfiguration()
        ssh.enabled = true
        ssh.host = "bastion.example.com"
        ssh.username = "deploy"
        for mode in [nil, "automatic"] {
            let connection = remote(sslMode: mode, ssh: ssh)
            let refusal = try #require(
                DriverSettingNotSupportedError.refusal(for: connection, pluginType: DuckDBDriverBeforeSSLMode.self)
            )
            #expect(refusal.setting == .tunnel)
        }
        let current = remote(sslMode: "automatic", ssh: ssh)
        #expect(DriverSettingNotSupportedError.refusal(for: current, pluginType: DuckDBDriverWithSSLMode.self) == nil)
    }

    @Test("A driver that declares the field is never refused")
    func currentDriverConnects() {
        for mode in ["disabled", "required", "verifyIdentity", "verifyFingerprint"] {
            #expect(
                DriverSettingNotSupportedError.refusal(for: remote(sslMode: mode), pluginType: DuckDBDriverWithSSLMode.self)
                    == nil,
                "\(mode)"
            )
        }
    }

    @Test("A type whose curated entry names no such field is never refused")
    func otherTypesAreUntouched() {
        let connection = DatabaseConnection(
            name: "pg", host: "db.internal", port: 5_432, type: .postgresql,
            additionalFields: ["duckdbSSLMode": "required"]
        )
        #expect(DriverSettingNotSupportedError.refusal(for: connection, pluginType: DuckDBDriverBeforeSSLMode.self) == nil)
    }
}
