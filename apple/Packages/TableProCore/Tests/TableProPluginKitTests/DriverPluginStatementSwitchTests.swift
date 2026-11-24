import Foundation
import TableProPluginKit
import Testing

private final class SessionDatabasePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Session Database"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Keeps its database on the session, where a statement can move it"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "SessionDB"
    static let databaseDisplayName = "Session Database"
    static let iconName = "cylinder"
    static let defaultPort = 1

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class PerRequestDatabasePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Per Request"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Names its database on every request"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "PerRequestDB"
    static let databaseDisplayName = "Per Request"
    static let iconName = "cylinder"
    static let defaultPort = 2
    static let statementsCanSwitchDatabase = false

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

struct DriverPluginStatementSwitchTests {
    @Test("A driver that declares nothing can have its database moved by a statement")
    func defaultIsTrue() {
        let pluginType: any DriverPlugin.Type = SessionDatabasePlugin.self
        let switches = pluginType.statementsCanSwitchDatabase
        #expect(switches)
    }

    @Test("A driver's own declaration is what it reports")
    func overrideIsReported() {
        let pluginType: any DriverPlugin.Type = PerRequestDatabasePlugin.self
        let switches = pluginType.statementsCanSwitchDatabase
        #expect(!switches)
    }
}
