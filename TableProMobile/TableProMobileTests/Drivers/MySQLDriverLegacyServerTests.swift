import Foundation
@testable import TableProMobile
import TableProModels
import Testing

@Suite("MySQL servers before 5.5 on iOS")
struct MySQLDriverLegacyServerTests {
    /// Measured: 4.1.22 answers `SHOW FULL TABLES` with 1064, 5.0.96 lists the type column.
    @Test("The table list asks a server before 5.0.2 for names alone")
    func tableListStatement() {
        #expect(MySQLDriver.tableListStatement(for: .mysql, banner: "4.1.22-standard") == "SHOW TABLES")
        #expect(MySQLDriver.tableListStatement(for: .mysql, banner: "5.0.1-alpha") == "SHOW TABLES")
        #expect(MySQLDriver.tableListStatement(for: .mysql, banner: "5.0.96-log") == "SHOW FULL TABLES")
        #expect(MySQLDriver.tableListStatement(for: .mariadb, banner: "5.3.12-MariaDB") == "SHOW FULL TABLES")
        #expect(MySQLDriver.tableListStatement(for: .mysql, banner: "8.4.11") == "SHOW FULL TABLES")
    }

    @Test("An unreadable banner or a fork keeps SHOW FULL TABLES")
    func tableListStatementWithoutALegacyBanner() {
        #expect(MySQLDriver.tableListStatement(for: .mysql, banner: nil) == "SHOW FULL TABLES")
        #expect(MySQLDriver.tableListStatement(for: .mysql, banner: "unknown") == "SHOW FULL TABLES")
        #expect(MySQLDriver.tableListStatement(for: .tidb, banner: "8.0.11-TiDB-v8.5.0") == "SHOW FULL TABLES")
        #expect(MySQLDriver.tableListStatement(for: .oceanbase, banner: nil) == "SHOW FULL TABLES")
    }

    /// Measured: 5.0.96 answers `REFERENTIAL_CONSTRAINTS` with 1109, 4.1.22 with 1146, 5.1.73 answers.
    @Test("Foreign keys skip the catalog below 5.1.10")
    func foreignKeyCatalogFloor() {
        #expect(!MySQLDriver.readsForeignKeyCatalog(for: .mysql, banner: "4.1.22-standard"))
        #expect(!MySQLDriver.readsForeignKeyCatalog(for: .mysql, banner: "5.0.96-log"))
        #expect(!MySQLDriver.readsForeignKeyCatalog(for: .mysql, banner: "5.1.9"))
        #expect(MySQLDriver.readsForeignKeyCatalog(for: .mysql, banner: "5.1.10"))
        #expect(MySQLDriver.readsForeignKeyCatalog(for: .mysql, banner: "5.1.73"))
        #expect(MySQLDriver.readsForeignKeyCatalog(for: .mysql, banner: nil))
        #expect(MySQLDriver.readsForeignKeyCatalog(for: .tidb, banner: "8.0.11-TiDB-v8.5.0"))
    }

    /// Measured: 4.1.22 labels `SHOW` strings charset 63, 5.0.96 labels them utf8.
    @Test("Only a server before 5.0 labels SHOW text binary")
    func showTextFloor() {
        #expect(MySQLDriver.labelsShowTextAsBinary(for: .mysql, banner: "4.1.22-standard"))
        #expect(!MySQLDriver.labelsShowTextAsBinary(for: .mysql, banner: "5.0.96-log"))
        #expect(!MySQLDriver.labelsShowTextAsBinary(for: .mysql, banner: nil))
        #expect(!MySQLDriver.labelsShowTextAsBinary(for: .oceanbase, banner: "4.1.22"))
    }
}
