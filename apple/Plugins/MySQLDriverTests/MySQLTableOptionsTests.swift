//
//  MySQLTableOptionsTests.swift
//  TableProTests
//

import TableProMySQLCore
import TableProPluginKit
import Testing

struct MySQLTableOptionsTests {
    private func statement(_ change: PluginTableOptionsChange) -> String? {
        MySQLTableOptions.statement(qualifiedTable: "`shop`.`orders`", change: change)
    }

    private func row(_ cells: String?...) -> [PluginCellValue] {
        cells.map(PluginCellValue.fromOptional)
    }

    private func driver(variant: String?) -> MySQLPluginDriver {
        MySQLPluginDriver(config: DriverConnectionConfig(
            host: "", port: 0, username: "", password: "", database: "",
            additionalFields: variant.map { ["driverVariant": $0] } ?? [:]
        ))
    }

    // MARK: - Statement

    @Test("A default change names both clauses")
    func defaultChange() {
        #expect(statement(PluginTableOptionsChange(characterSet: "utf8mb4", collation: "utf8mb4_bin"))
            == "ALTER TABLE `shop`.`orders` DEFAULT CHARACTER SET = utf8mb4 COLLATE = utf8mb4_bin")
    }

    @Test("A convert rewrites the columns with CONVERT TO")
    func convert() {
        let change = PluginTableOptionsChange(characterSet: "latin1", collation: "latin1_bin", convertsColumns: true)
        #expect(statement(change) == "ALTER TABLE `shop`.`orders` CONVERT TO CHARACTER SET latin1 COLLATE latin1_bin")
    }

    @Test("A convert with no character set cannot be spelled")
    func convertNeedsACharacterSet() {
        #expect(statement(PluginTableOptionsChange(collation: "latin1_bin", convertsColumns: true)) == nil)
    }

    @Test("The counter alone is its own statement")
    func counterAlone() {
        #expect(statement(PluginTableOptionsChange(autoIncrement: 500)) == "ALTER TABLE `shop`.`orders` AUTO_INCREMENT = 500")
    }

    @Test("A default change and the counter share one statement, joined by a comma")
    func defaultChangeWithCounter() {
        let change = PluginTableOptionsChange(characterSet: "latin1", collation: "latin1_bin", autoIncrement: 500)
        #expect(statement(change)
            == "ALTER TABLE `shop`.`orders` DEFAULT CHARACTER SET = latin1 COLLATE = latin1_bin, AUTO_INCREMENT = 500")
    }

    @Test("A convert and the counter share one statement")
    func convertWithCounter() {
        let change = PluginTableOptionsChange(
            characterSet: "utf8mb4", collation: "utf8mb4_bin", convertsColumns: true, autoIncrement: 7
        )
        #expect(statement(change)
            == "ALTER TABLE `shop`.`orders` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_bin, AUTO_INCREMENT = 7")
    }

    @Test("A change that names nothing is no statement")
    func emptyChange() {
        #expect(statement(PluginTableOptionsChange()) == nil)
        #expect(statement(PluginTableOptionsChange(characterSet: "", collation: "")) == nil)
    }

    @Test("A name the catalog could not have listed is backticked, never spliced in bare")
    func unsafeNameIsQuoted() {
        let change = PluginTableOptionsChange(characterSet: "utf8mb4; DROP TABLE x", collation: "a`b")
        #expect(statement(change)
            == "ALTER TABLE `shop`.`orders` DEFAULT CHARACTER SET = `utf8mb4; DROP TABLE x` COLLATE = `a``b`")
    }

    // MARK: - Flavors

    @Test("Only MySQL and MariaDB write table options")
    func writingFlavors() {
        #expect(MySQLTableOptions.writesOptions(flavor: .mysql))
        #expect(MySQLTableOptions.writesOptions(flavor: .mariadb))
        #expect(!MySQLTableOptions.writesOptions(flavor: .tidb(version: nil)))
        #expect(!MySQLTableOptions.writesOptions(flavor: .oceanbase(version: nil)))
        #expect(!MySQLTableOptions.writesOptions(flavor: .databend))
    }

    @Test("Every flavor but Databend reads the catalog")
    func catalogFlavors() {
        #expect(MySQLTableOptions.readsCatalog(flavor: .mysql))
        #expect(MySQLTableOptions.readsCatalog(flavor: .mariadb))
        #expect(MySQLTableOptions.readsCatalog(flavor: .tidb(version: nil)))
        #expect(MySQLTableOptions.readsCatalog(flavor: .oceanbase(version: nil)))
        #expect(!MySQLTableOptions.readsCatalog(flavor: .databend))
    }

    @Test("The driver qualifies the table, and answers nil on OceanBase and Databend")
    func driverStatementFollowsTheFlavor() {
        let change = PluginTableOptionsChange(autoIncrement: 10)
        #expect(driver(variant: nil).tableOptionsStatement(table: "orders", schema: "shop", change: change)
            == "ALTER TABLE `shop`.`orders` AUTO_INCREMENT = 10")
        #expect(driver(variant: nil).tableOptionsStatement(table: "orders", schema: nil, change: change)
            == "ALTER TABLE `orders` AUTO_INCREMENT = 10")
        #expect(driver(variant: "OceanBase").tableOptionsStatement(table: "orders", schema: "shop", change: change) == nil)
        #expect(driver(variant: "Databend").tableOptionsStatement(table: "orders", schema: "shop", change: change) == nil)
    }

    // MARK: - Reading a table

    @Test("The table read filters by schema and name and counts AUTO_INCREMENT columns by exact name")
    func tableQueryShape() {
        let sql = MySQLTableOptions.tableQuery(schema: "sh'op", table: "orders")
        #expect(sql.contains("t.TABLE_SCHEMA = 'sh''op' AND t.TABLE_NAME = 'orders'"))
        #expect(sql.contains("t.TABLE_COLLATION, t.AUTO_INCREMENT"))
        #expect(sql.contains("CAST(c.TABLE_NAME AS BINARY) = CAST(t.TABLE_NAME AS BINARY)"))
        #expect(sql.contains("c.EXTRA LIKE '%auto_increment%'"))
    }

    @Test("A session's temporary row is skipped for the base table it hides")
    func temporaryRowIsSkipped() throws {
        let rows = [
            row("orders", "TEMPORARY", "utf8mb4_bin", nil, "0"),
            row("orders", "BASE TABLE", "latin1_swedish_ci", "4", "1")
        ]
        let parsed = try #require(MySQLTableOptionsRow.row(named: "orders", in: rows))
        #expect(parsed == MySQLTableOptionsRow(
            type: "BASE TABLE", collation: "latin1_swedish_ci", autoIncrement: 4, hasAutoIncrementColumn: true
        ))
    }

    @Test("The row naming the table exactly wins over a case variant")
    func exactNameWins() throws {
        let rows = [
            row("Orders", "BASE TABLE", "latin1_bin", nil, "0"),
            row("orders", "BASE TABLE", "utf8mb4_bin", nil, "0")
        ]
        #expect(try #require(MySQLTableOptionsRow.row(named: "orders", in: rows)).collation == "utf8mb4_bin")
    }

    @Test("A view or a sequence has no table options", arguments: ["VIEW", "SYSTEM VIEW", "SEQUENCE"])
    func nonTablesHaveNone(type: String) throws {
        let parsed = try #require(MySQLTableOptionsRow.row(named: "v", in: [row("v", type, nil, nil, "0")]))
        #expect(MySQLTableOptions.tableOptions(row: parsed, createTableOptions: nil) == nil)
    }

    @Test("A base table and a system-versioned table read their collation's character set")
    func tableReadsItsCharacterSet() throws {
        for type in ["BASE TABLE", "SYSTEM VERSIONED"] {
            let parsed = try #require(MySQLTableOptionsRow.row(
                named: "t", in: [row("t", type, "utf8mb4_uca1400_ai_ci", nil, "0")]
            ))
            #expect(MySQLTableOptions.tableOptions(row: parsed, createTableOptions: nil)
                == PluginTableOptions(characterSet: "utf8mb4", collation: "utf8mb4_uca1400_ai_ci", autoIncrement: nil))
        }
    }

    @Test("A collation's character set is its prefix", arguments: [
        ("utf8mb4_uca1400_ai_ci", "utf8mb4"),
        ("latin1_swedish_ci", "latin1"),
        ("utf8mb3_general_ci", "utf8mb3"),
        ("binary", "binary")
    ])
    func characterSetOfCollation(collation: String, expected: String) {
        #expect(MySQLTableOptions.characterSet(ofCollation: collation) == expected)
    }

    @Test("No collation names no character set")
    func noCollation() {
        #expect(MySQLTableOptions.characterSet(ofCollation: nil) == nil)
        #expect(MySQLTableOptions.characterSet(ofCollation: "") == nil)
    }

    // MARK: - Counter

    private func tableRow(autoIncrement: UInt64?, hasColumn: Bool) -> MySQLTableOptionsRow {
        MySQLTableOptionsRow(
            type: "BASE TABLE", collation: "utf8mb4_bin", autoIncrement: autoIncrement, hasAutoIncrementColumn: hasColumn
        )
    }

    @Test("A table without an AUTO_INCREMENT column has no counter, whatever the catalog says")
    func noColumnNoCounter() {
        #expect(MySQLTableOptions.counter(row: tableRow(autoIncrement: 50, hasColumn: false), createTableOptions: nil) == nil)
    }

    @Test("MySQL reads the counter from SHOW CREATE TABLE over its stale catalog")
    func mysqlReadsTheOptionsLine() {
        let options = ["ENGINE": "InnoDB", "AUTO_INCREMENT": "9", "CHARSET": "utf8mb4"]
        #expect(MySQLTableOptions.counter(row: tableRow(autoIncrement: 4, hasColumn: true), createTableOptions: options) == 9)
    }

    @Test("An options line with no AUTO_INCREMENT clause means the next value is 1")
    func missingClauseIsOne() {
        let options = ["ENGINE": "InnoDB", "CHARSET": "utf8mb4"]
        #expect(MySQLTableOptions.counter(row: tableRow(autoIncrement: 4, hasColumn: true), createTableOptions: options) == 1)
    }

    @Test("An options line printed without ENGINE says nothing, so the catalog answers")
    func blankOptionsLineFallsBackToTheCatalog() {
        #expect(MySQLTableOptions.counter(row: tableRow(autoIncrement: 4, hasColumn: true), createTableOptions: [:]) == 4)
    }

    @Test("MariaDB reads its live catalog, and an empty value there is 1")
    func mariadbReadsTheCatalog() {
        #expect(MySQLTableOptions.counter(row: tableRow(autoIncrement: 100, hasColumn: true), createTableOptions: nil) == 100)
        #expect(MySQLTableOptions.counter(row: tableRow(autoIncrement: nil, hasColumn: true), createTableOptions: nil) == 1)
    }

    // MARK: - Schema defaults

    @Test("A schema's defaults come from its own SCHEMATA row")
    func schemaDefaults() {
        let rows = [
            row("Shop", "latin1", "latin1_swedish_ci"),
            row("shop", "utf8mb4", "utf8mb4_uca1400_ai_ci")
        ]
        #expect(MySQLTableOptions.schemaDefaults(named: "shop", in: rows)
            == PluginTableOptions(characterSet: "utf8mb4", collation: "utf8mb4_uca1400_ai_ci"))
        #expect(MySQLTableOptions.schemaDefaults(named: "missing", in: []) == nil)
        #expect(MySQLTableOptions.schemaDefaultsQuery(schema: "shop").contains("SCHEMA_NAME = 'shop'"))
    }

    // MARK: - Catalog

    @Test("Engines the server cannot create are left out, and its default is named")
    func engines() {
        let engines = MySQLTableOptions.engines(fromRows: [
            row("MyISAM", "YES"),
            row("FEDERATED", "NO"),
            row("InnoDB", "DEFAULT"),
            row("ndbcluster", "DISABLED"),
            row("Aria", "YES")
        ])
        let names = engines.map(\.name)
        let defaults = engines.filter(\.isDefault).map(\.name)
        #expect(names == ["Aria", "InnoDB", "MyISAM"])
        #expect(defaults == ["InnoDB"])
    }

    @Test("Each character set lists its own collations, sorted, its default among them")
    func catalogGroupsCollations() {
        let catalog = MySQLTableOptions.catalog(
            characterSets: [
                MySQLCharsetDefault(charset: "latin1", defaultCollation: "latin1_swedish_ci", description: "cp1252 West European"),
                MySQLCharsetDefault(charset: "utf8mb4", defaultCollation: "utf8mb4_uca1400_ai_ci", description: nil)
            ],
            collations: [
                MySQLCollationEntry(collation: "utf8mb4_general_ci", charset: "utf8mb4"),
                MySQLCollationEntry(collation: "latin1_bin", charset: "latin1"),
                MySQLCollationEntry(collation: "latin1_swedish_ci", charset: "latin1"),
                MySQLCollationEntry(collation: "utf8mb4_bin", charset: "utf8mb4")
            ],
            engines: [MySQLStorageEngine(name: "Aria", isDefault: false), MySQLStorageEngine(name: "InnoDB", isDefault: true)]
        )
        #expect(catalog.characterSets == [
            PluginCharacterSet(
                name: "latin1",
                defaultCollation: "latin1_swedish_ci",
                collations: ["latin1_bin", "latin1_swedish_ci"],
                description: "cp1252 West European"
            ),
            PluginCharacterSet(
                name: "utf8mb4",
                defaultCollation: "utf8mb4_uca1400_ai_ci",
                collations: ["utf8mb4_bin", "utf8mb4_general_ci", "utf8mb4_uca1400_ai_ci"],
                description: nil
            )
        ])
        #expect(catalog.engines == ["Aria", "InnoDB"])
        #expect(catalog.defaultEngine == "InnoDB")
    }

    @Test("The catalog column probes name information_schema's own tables")
    func catalogColumnProbes() {
        #expect(MySQLCatalogColumn.fullCollationName.presenceQuery.contains(
            "TABLE_NAME = 'COLLATION_CHARACTER_SET_APPLICABILITY'"
        ))
        #expect(MySQLCatalogColumn.fullCollationName.presenceQuery.contains("COLUMN_NAME = 'FULL_COLLATION_NAME'"))
        #expect(MySQLCatalogColumn.checkConstraintLevel.presenceQuery.contains("TABLE_NAME = 'CHECK_CONSTRAINTS'"))
        #expect(MySQLCatalogColumn.checkConstraintLevel.presenceQuery.contains("COLUMN_NAME = 'LEVEL'"))
    }
}
