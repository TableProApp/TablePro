import Foundation
import TableProDatabase
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import Testing

struct ClickHouseOnIOSTests {
    private func driver() -> PluginBackedDriver {
        let config = DriverConnectionConfig(host: "ch.example.com", port: 8_123, username: "u", password: "p", database: "default")
        return PluginBackedDriver(
            plugin: ClickHousePluginDriver(config: config),
            dialedHosts: [],
            rowIdentity: .everyColumn,
            readsOnly: { _ in true }
        )
    }

    // The sorting key ClickHouse reports as its primary key is not unique: a key-only predicate deletes every row with
    // that key, and a plain UPDATE fails before 25.7 (measured on 25.8 without block numbers: NOT_IMPLEMENTED).
    @Test("A row edit matches every column the row was read with, pinned to the part its lookup finds")
    func editMatchesTheWholeRow() throws {
        let writes = try driver().updateWrites(
            table: "events",
            schema: nil,
            columns: ["id", "name", "note"],
            originalRow: ["1", "signup", nil],
            changes: [(column: "name", value: "purchase")]
        )

        let write = try #require(writes.first)
        #expect(write.statement
            == "UPDATE `events` SET `name` = ? WHERE `id` = ? AND `name` = ? AND `note` IS NULL AND _part IN (?)")
        #expect(write.parameters == ["purchase", "1", "signup"])
        #expect(write.lookup?.query == "SELECT _part FROM `events` WHERE `id` = ? AND `name` = ? AND `note` IS NULL LIMIT 2")
    }

    @Test("A row delete matches every column the row was read with, pinned to the part its lookup finds")
    func deleteMatchesTheWholeRow() throws {
        let writes = try driver().deleteWrites(
            table: "events", schema: nil, columns: ["id", "name"], originalRow: ["1", "signup"]
        )

        #expect(writes.map(\.statement) == ["DELETE FROM `events` WHERE `id` = ? AND `name` = ? AND _part IN (?)"])
    }

    @Test("A new row names only the columns it sets")
    func insertNamesOnlySetColumns() throws {
        let writes = try driver().insertWrites(
            table: "events", schema: nil, columns: ["id", "name", "note"], values: [(column: "name", value: "x")]
        )

        #expect(writes.map(\.statement) == ["INSERT INTO `events` (`name`) VALUES (?)"])
    }

    @Test("String literals escape backslashes the way ClickHouse reads them")
    func literalsEscapeBackslashes() {
        #expect(driver().escapeStringLiteral(#"a\'b"#) == #"a\\''b"#)
    }

    @Test("Names are quoted with backquotes, a backslash or backquote inside escaped")
    func namesAreBackquoted() {
        #expect(SQLBuilder.quoteIdentifier("a`b\\c", for: .clickhouse) == "`a``b\\\\c`")
        #expect(SQLBuilder.buildSelect(table: "events", schema: nil, type: .clickhouse, limit: 10, offset: 20)
            == "SELECT * FROM `events` LIMIT 10 OFFSET 20")
    }

    @Test("The factory opens ClickHouse through the plugin driver, matching rows on every column")
    func factoryOpensClickHouse() throws {
        let connection = DatabaseConnection(type: .clickhouse, host: "ch.example.com", port: 8_123, database: "default")

        let opened = try IOSDriverFactory(materializer: CertificateMaterializer(store: InMemoryCertificateStore()))
            .createDriver(for: connection, password: "p")

        let writer = try #require(opened as? PluginBackedDriver)
        #expect(writer.rowIdentity == .everyColumn)
        #expect(writer.supportsTransactions == false)
    }

    @Test("Each iOS SSL mode reaches the plugin as the Mac mode of the same name, with its files")
    func sslModesMapToTheMacModes() {
        let cases: [(TableProModels.SSLConfiguration.SSLMode, TableProPluginKit.SSLMode)] = [
            (.disable, .disabled), (.require, .required), (.verifyCa, .verifyCa), (.verifyFull, .verifyIdentity)
        ]
        for (iosMode, macMode) in cases {
            let ssl = DriverSSLConfiguration(
                mode: iosMode, caCertificatePath: "/ca.pem", clientCertificatePath: "/cert.pem", clientKeyPath: "/key.pem"
            )
            let mapped = ssl.pluginConfiguration
            #expect(mapped.mode == macMode)
            #expect(mapped.caCertificatePath == "/ca.pem")
            #expect(mapped.clientCertificatePath == "/cert.pem")
            #expect(mapped.clientKeyPath == "/key.pem")
        }
    }

    @Test("The Mac's Preferred reaches the plugin as Preferred, so the shared driver decides what it means")
    func preferredMapsToPreferred() {
        let ssl = DriverSSLConfiguration(mode: .require, isPreferred: true)
        #expect(ssl.pluginConfiguration.mode == .preferred)
    }
}
