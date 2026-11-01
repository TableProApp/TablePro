import Foundation
import TableProPluginKit

final class StarRocksPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "StarRocks Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "StarRocks support via libmariadb"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "StarRocks"
    static let databaseDisplayName = "StarRocks"
    static let iconName = "starrocks-icon"
    static let defaultPort = 9_030
    static let isDownloadable = true
    static let urlSchemes = ["starrocks"]
    static let brandColorHex = "#01808F"
    static let additionalConnectionFields = MySQLPlugin.additionalConnectionFields.filter {
        $0.id == "mysqlIdleReleaseMinutes"
    }

    static let postConnectActions: [PostConnectAction] = [.selectDatabaseFromLastSession, .selectSchemaFromLastSession]
    static let databaseGroupingStrategy: GroupingStrategy = .hierarchicalSchema
    static let containerEntityName = "Catalog"
    static let defaultGroupName = "default"
    static let defaultSchemaName = ""
    static let systemSchemaNames = ["_statistics_", "information_schema", "sys"]
    static let supportsSchemaSwitching = true
    static let sqlDialect = MySQLPlugin.sqlDialect
    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .defaultValue, .comment]

    // Measured on 4.1.7. `EXPLAIN ANALYZE` colors its report with terminal escape codes.
    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .plainText),
        ExplainVariant(id: "logical", label: "EXPLAIN LOGICAL", sqlPrefix: "EXPLAIN LOGICAL", format: .plainText),
        ExplainVariant(id: "verbose", label: "EXPLAIN VERBOSE", sqlPrefix: "EXPLAIN VERBOSE", format: .plainText),
        ExplainVariant(id: "costs", label: "EXPLAIN COSTS", sqlPrefix: "EXPLAIN COSTS", format: .plainText),
    ]

    static let columnTypesByCategory: [String: [String]] = [
        "Integer": ["TINYINT", "SMALLINT", "INT", "BIGINT", "LARGEINT"],
        "Float": ["FLOAT", "DOUBLE", "DECIMAL"],
        "String": ["CHAR", "VARCHAR", "STRING"],
        "Date": ["DATE", "DATETIME"],
        "Binary": ["BINARY", "VARBINARY"],
        "Boolean": ["BOOLEAN"],
        "Semi-structured": ["JSON", "ARRAY", "MAP", "STRUCT"],
        "Aggregate": ["BITMAP", "HLL", "PERCENTILE"],
    ]

    static let supportsForeignKeys = false
    static let supportsSchemaEditing = false
    static let supportsImport = false
    static let supportsForeignKeyDisable = false
    static let supportsAddIndex = false
    static let supportsDropIndex = false
    static let supportsModifyPrimaryKey = false

    static func driverVariant(for databaseTypeId: String) -> String? {
        databaseTypeId == Self.databaseTypeId ? databaseTypeId : nil
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        MySQLPluginDriver(config: config)
    }
}
