import Foundation

public protocol DriverPlugin: TableProPlugin {
    static var databaseTypeId: String { get }
    static var databaseDisplayName: String { get }
    static var iconName: String { get }
    static var defaultPort: Int { get }
    static var additionalConnectionFields: [ConnectionField] { get }
    static var additionalDatabaseTypeIds: [String] { get }

    static func driverVariant(for databaseTypeId: String) -> String?

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver

    // MARK: - UI/Capability Metadata

    static var requiresAuthentication: Bool { get }
    static var connectionMode: ConnectionMode { get }
    static var urlSchemes: [String] { get }
    static var fileExtensions: [String] { get }
    static var brandColorHex: String { get }
    static var queryLanguageName: String { get }
    static var editorLanguage: EditorLanguage { get }
    static var supportsForeignKeys: Bool { get }
    static var supportsSchemaEditing: Bool { get }
    static var supportsDatabaseSwitching: Bool { get }
    static var supportsSchemaSwitching: Bool { get }
    static var supportsImport: Bool { get }
    static var supportsExport: Bool { get }
    static var supportsHealthMonitor: Bool { get }
    static var systemDatabaseNames: [String] { get }
    static var systemSchemaNames: [String] { get }
    static var databaseGroupingStrategy: GroupingStrategy { get }
    static var defaultGroupName: String { get }
    static var columnTypesByCategory: [String: [String]] { get }
    static var sqlDialect: SQLDialectDescriptor? { get }
    static var statementCompletions: [CompletionEntry] { get }
    static var tableEntityName: String { get }
    static var supportsCascadeDrop: Bool { get }
    static var supportsForeignKeyDisable: Bool { get }
    static var immutableColumns: [String] { get }
    static var supportsReadOnlyMode: Bool { get }
    static var defaultSchemaName: String { get }
    static var requiresReconnectForDatabaseSwitch: Bool { get }
    static var structureColumnFields: [StructureColumnField] { get }
    static var defaultPrimaryKeyColumn: String? { get }
    static var supportsQueryProgress: Bool { get }
    static var supportsSSH: Bool { get }
    static var supportsSSL: Bool { get }
    static var navigationModel: NavigationModel { get }
    static var explainVariants: [ExplainVariant] { get }
    static var pathFieldRole: PathFieldRole { get }
    static var isDownloadable: Bool { get }
    static var postConnectActions: [PostConnectAction] { get }
    static var parameterStyle: ParameterStyle { get }
    static var supportsDropDatabase: Bool { get }

    // Schema editing granularity
    static var supportsAddColumn: Bool { get }
    static var supportsModifyColumn: Bool { get }
    static var supportsDropColumn: Bool { get }
    static var supportsRenameColumn: Bool { get }
    static var supportsAddIndex: Bool { get }
    static var supportsDropIndex: Bool { get }
    static var supportsModifyPrimaryKey: Bool { get }
}

public extension DriverPlugin {
    static var additionalConnectionFields: [ConnectionField] { [] }
    static var additionalDatabaseTypeIds: [String] { [] }
    static func driverVariant(for databaseTypeId: String) -> String? { nil }

    // MARK: - UI/Capability Metadata Defaults

    static var requiresAuthentication: Bool { true }
    static var connectionMode: ConnectionMode { .network }
    static var urlSchemes: [String] { [] }
    static var fileExtensions: [String] { [] }
    static var brandColorHex: String { "#808080" }
    static var queryLanguageName: String { "SQL" }
    static var editorLanguage: EditorLanguage { .sql }
    static var supportsForeignKeys: Bool { true }
    static var supportsSchemaEditing: Bool { true }
    static var supportsDatabaseSwitching: Bool { true }
    static var supportsSchemaSwitching: Bool { false }
    static var supportsImport: Bool { true }
    static var supportsExport: Bool { true }
    static var supportsHealthMonitor: Bool { true }
    static var systemDatabaseNames: [String] { [] }
    static var systemSchemaNames: [String] { [] }
    static var databaseGroupingStrategy: GroupingStrategy { .byDatabase }
    static var defaultGroupName: String { "main" }
    static var columnTypesByCategory: [String: [String]] {
        [
            "Integer": ["INTEGER", "INT", "SMALLINT", "BIGINT", "TINYINT"],
            "Float": ["FLOAT", "DOUBLE", "DECIMAL", "NUMERIC", "REAL"],
            "String": ["VARCHAR", "CHAR", "TEXT", "NVARCHAR", "NCHAR"],
            "Date": ["DATE", "TIME", "DATETIME", "TIMESTAMP"],
            "Binary": ["BLOB", "BINARY", "VARBINARY"],
            "Boolean": ["BOOLEAN", "BOOL"],
            "JSON": ["JSON"]
        ]
    }
    static var sqlDialect: SQLDialectDescriptor? { nil }
    static var statementCompletions: [CompletionEntry] { [] }
    static var tableEntityName: String { "Tables" }
    static var supportsCascadeDrop: Bool { false }
    static var supportsForeignKeyDisable: Bool { true }
    static var immutableColumns: [String] { [] }
    static var supportsReadOnlyMode: Bool { true }
    static var defaultSchemaName: String { "public" }
    static var requiresReconnectForDatabaseSwitch: Bool { false }
    static var structureColumnFields: [StructureColumnField] {
        [.name, .type, .nullable, .defaultValue, .autoIncrement, .comment]
    }
    static var defaultPrimaryKeyColumn: String? { nil }
    static var supportsQueryProgress: Bool { false }
    static var supportsSSH: Bool { true }
    static var supportsSSL: Bool { true }
    static var navigationModel: NavigationModel { .standard }
    static var explainVariants: [ExplainVariant] { [] }
    static var pathFieldRole: PathFieldRole { .database }
    static var parameterStyle: ParameterStyle { .questionMark }
    static var isDownloadable: Bool { false }
    static var postConnectActions: [PostConnectAction] { [] }
    static var supportsDropDatabase: Bool { false }

    // Schema editing granularity
    static var supportsAddColumn: Bool { true }
    static var supportsModifyColumn: Bool { true }
    static var supportsDropColumn: Bool { true }
    static var supportsRenameColumn: Bool { false }
    static var supportsAddIndex: Bool { true }
    static var supportsDropIndex: Bool { true }
    static var supportsModifyPrimaryKey: Bool { true }
}
