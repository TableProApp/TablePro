import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class VariantReportingPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Variant Reporting"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Names a variant for TiDB rows and none for MySQL rows"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "MySQL"
    static let databaseDisplayName = "MySQL"
    static let iconName = "mysql-icon"
    static let defaultPort = 3_306

    static func driverVariant(for databaseTypeId: String) -> String? {
        databaseTypeId == "TiDB" ? "TiDB" : nil
    }

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

private final class KeyDocumentPlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "Key Document"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Reads a service account key from its field or, failing that, the password"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "BigQuery"
    static let databaseDisplayName = "BigQuery"
    static let iconName = "bigquery-icon"
    static let defaultPort = 0
    static let additionalConnectionFields: [ConnectionField] = [
        ConnectionField(id: "bqServiceAccountJson", label: "Key", fieldType: .secure, hidesPassword: true)
    ]

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        fatalError("Not used in tests")
    }
}

@MainActor
struct DatabaseDriverFactoryFieldTests {
    @Test("A key path stored as a plain field never reaches the driver; an inline key does")
    func storedKeyPathIsDropped() {
        let path = DatabaseConnection(
            name: "Warehouse", host: "", port: 0, type: DatabaseType(rawValue: "BigQuery"),
            additionalFields: ["bqServiceAccountJson": "~/.config/gcloud/sa.json", "bqProjectId": "attacker-project"]
        )
        let inline = DatabaseConnection(
            name: "Reports", host: "", port: 0, type: DatabaseType(rawValue: "BigQuery"),
            additionalFields: ["bqServiceAccountJson": #"{"type":"service_account"}"#]
        )

        let pathFields = DatabaseDriverFactory.buildAdditionalFields(for: path, plugin: KeyDocumentPlugin())
        let inlineFields = DatabaseDriverFactory.buildAdditionalFields(for: inline, plugin: KeyDocumentPlugin())

        #expect(pathFields["bqServiceAccountJson"] == nil)
        #expect(pathFields["bqProjectId"] == "attacker-project")
        #expect(inlineFields["bqServiceAccountJson"] == #"{"type":"service_account"}"#)
    }

    @Test("A password a key field stands in for reaches the driver only as an inline key")
    func keyPasswordMustBeInline() {
        let inline = #"{"type":"service_account"}"#

        #expect(DatabaseDriverFactory.keyDocumentSafePassword("~/.config/gcloud/sa.json", plugin: KeyDocumentPlugin()).isEmpty)
        #expect(DatabaseDriverFactory.keyDocumentSafePassword(inline, plugin: KeyDocumentPlugin()) == inline)
        #expect(DatabaseDriverFactory.keyDocumentSafePassword("/var/secret", plugin: VariantReportingPlugin()) == "/var/secret")
    }

    @Test("A stored driver variant never reaches the driver; the plugin's own answer does")
    func storedVariantIsIgnored() {
        let plain = DatabaseConnection(
            name: "Shop", host: "db.example.com", port: 3_306, type: .mysql,
            additionalFields: ["driverVariant": "Databend"]
        )
        let tidb = DatabaseConnection(
            name: "Cluster", host: "tidb.example.com", port: 4_000, type: DatabaseType(rawValue: "TiDB"),
            additionalFields: ["driverVariant": "Databend"]
        )

        let plainFields = DatabaseDriverFactory.buildAdditionalFields(for: plain, plugin: VariantReportingPlugin())
        let tidbFields = DatabaseDriverFactory.buildAdditionalFields(for: tidb, plugin: VariantReportingPlugin())

        #expect(plainFields["driverVariant"] == nil)
        #expect(tidbFields["driverVariant"] == "TiDB")
    }

    @Test("Values the factory sets at connect are dropped from a stored row, and its own fields stay")
    func storedFactoryValuesAreDropped() {
        let connection = DatabaseConnection(
            name: "Shop", host: "db.example.com", port: 3_306, type: .mysql,
            additionalFields: [
                "enableCleartextPlugin": "true",
                "connectionId": UUID().uuidString,
                "connectionPurpose": "metadata",
                "connectTimeoutMilliseconds": "1",
                "mysqlConnectionEncoding": "utf8ViaLatin1",
            ]
        )

        let fields = DatabaseDriverFactory.buildAdditionalFields(for: connection, plugin: VariantReportingPlugin())

        #expect(fields["enableCleartextPlugin"] == nil)
        #expect(fields["connectionId"] == nil)
        #expect(fields["connectionPurpose"] == nil)
        #expect(fields["connectTimeoutMilliseconds"] == nil)
        #expect(fields["mysqlConnectionEncoding"] == "utf8ViaLatin1")
    }

    @Test("The remote SQLite marker on an effective connection still reaches the metadata driver")
    func effectiveRemoteSQLiteFieldsSurvive() {
        let effective = DatabaseConnection(name: "Notes", type: .sqlite).openingRemoteSQLiteSession(
            host: "127.0.0.1",
            port: 60_123,
            token: "token",
            remotePath: "/srv/notes.db",
            field: .database
        )

        let fields = DatabaseDriverFactory.buildAdditionalFields(for: effective, plugin: VariantReportingPlugin())

        #expect(fields[RemoteSQLiteWire.backendFieldKey] == RemoteSQLiteWire.agentBackendValue)
        #expect(fields[RemoteSQLiteWire.tokenFieldKey] == "token")
    }
}
