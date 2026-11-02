import Foundation
import TableProPluginKit
import Testing

private final class EveryModeDriverPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Every Mode"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Declares no TLS modes of its own"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "EveryModeDB"
    static let databaseDisplayName = "Every Mode"
    static let iconName = "cylinder"
    static let defaultPort = 1

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class PlainTCPDriverPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Plain TCP"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Speaks plain TCP only"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "PlainTCPDB"
    static let databaseDisplayName = "Plain TCP"
    static let iconName = "cylinder"
    static let defaultPort = 2
    static let supportedSSLModes: [SSLMode] = [.disabled, .preferred]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

struct DriverPluginSSLModesTests {
    @Test("A driver that declares nothing supports every SSL mode")
    func defaultIsEveryMode() {
        #expect(EveryModeDriverPlugin.supportedSSLModes == SSLMode.allCases)
    }

    @Test("A driver's own list is what it reports")
    func overrideIsReported() {
        let pluginType: any DriverPlugin.Type = PlainTCPDriverPlugin.self
        #expect(pluginType.supportedSSLModes == [.disabled, .preferred])
    }
}
