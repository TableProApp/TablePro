import Foundation
@testable import TablePro
import TableProPluginKit
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

struct SSLModeNotSupportedErrorTests {
    private func connection(_ type: DatabaseType, mode: SSLMode) -> DatabaseConnection {
        DatabaseConnection(name: "Ledger", host: "db.example.com", type: type, sslConfig: SSLConfiguration(mode: mode))
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
}
