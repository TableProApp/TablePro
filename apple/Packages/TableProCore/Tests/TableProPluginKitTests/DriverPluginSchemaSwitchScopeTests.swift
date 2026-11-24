import Foundation
import TableProPluginKit
import Testing

private final class LabelOnlySchemaPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Label Only"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Switches schemas without declaring where names resolve"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "LabelOnlyDB"
    static let databaseDisplayName = "Label Only"
    static let iconName = "cylinder"
    static let defaultPort = 1
    static let supportsSchemaSwitching = true

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class SearchPathSchemaPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Search Path"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Moves the session's name resolution on a schema switch"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "SearchPathDB"
    static let databaseDisplayName = "Search Path"
    static let iconName = "cylinder"
    static let defaultPort = 2
    static let supportsSchemaSwitching = true
    static let schemaSwitchScopesUnqualifiedNames = true

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

struct DriverPluginSchemaSwitchScopeTests {
    @Test("A driver that declares nothing reads as a label-only schema switch")
    func defaultIsLabelOnly() {
        let pluginType: any DriverPlugin.Type = LabelOnlySchemaPlugin.self
        let scoped = pluginType.schemaSwitchScopesUnqualifiedNames
        #expect(!scoped)
    }

    @Test("A driver's own declaration is what it reports")
    func overrideIsReported() {
        let pluginType: any DriverPlugin.Type = SearchPathSchemaPlugin.self
        let scoped = pluginType.schemaSwitchScopesUnqualifiedNames
        #expect(scoped)
    }
}
