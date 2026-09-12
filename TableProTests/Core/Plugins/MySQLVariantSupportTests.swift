//
//  MySQLVariantSupportTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("TiDB and Databend support decisions", .serialized)
@MainActor
struct MySQLVariantSupportTests {
    private static func mysqlPluginSnapshot() throws -> PluginMetadataSnapshot {
        let mysql = try #require(PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: "MySQL"))
        return mysql.withExplainVariants([
            ExplainVariant(id: "explain", label: "EXPLAIN", sqlPrefix: "EXPLAIN", format: .mysqlComposite),
            ExplainVariant(id: "explain-json", label: "EXPLAIN (JSON)", sqlPrefix: "EXPLAIN FORMAT=JSON", format: .mysqlComposite),
        ])
    }

    @Test("Neither variant inherits EXPLAIN FORMAT=JSON from the MySQL plugin", arguments: ["TiDB", "Databend"])
    func explainVariantsStayCurated(typeId: String) throws {
        let registry = PluginMetadataRegistry.shared
        registry.registerVariant(pluginSnapshot: try Self.mysqlPluginSnapshot(), forTypeId: typeId, primaryTypeId: "MySQL")
        let variants = try #require(registry.snapshot(forRegisteredTypeId: typeId)).explainVariants
        #expect(variants.map(\.sqlPrefix) == ["EXPLAIN", "EXPLAIN ANALYZE"])
        #expect(variants.allSatisfy { $0.format == .plainText })
        #expect(ExplainFormatResolver.resolve(declared: .plainText, databaseType: DatabaseType(rawValue: typeId)) == .plainText)
    }

    @Test("TiDB keeps its type list without the spatial group once the MySQL plugin registers")
    func tidbColumnTypesSurviveRegistration() throws {
        let registry = PluginMetadataRegistry.shared
        registry.registerVariant(pluginSnapshot: try Self.mysqlPluginSnapshot(), forTypeId: "TiDB", primaryTypeId: "MySQL")
        let types = try #require(registry.snapshot(forRegisteredTypeId: "TiDB")).editor.columnTypesByCategory
        #expect(types["Spatial"] == nil)
        #expect(types["JSON"] == ["JSON"])
    }

    @Test("Databend keeps its own types and case folding once the MySQL plugin registers")
    func databendEditorSurvivesRegistration() throws {
        let registry = PluginMetadataRegistry.shared
        registry.registerVariant(pluginSnapshot: try Self.mysqlPluginSnapshot(), forTypeId: "Databend", primaryTypeId: "MySQL")
        let snapshot = try #require(registry.snapshot(forRegisteredTypeId: "Databend"))
        #expect(snapshot.editor.columnTypesByCategory["Semi-structured"]?.contains("VARIANT") == true)
        #expect(snapshot.editor.columnTypesByCategory["String"] == ["VARCHAR"])
        #expect(snapshot.editor.sqlDialect?.caseSensitivityStyle == .caseFoldFunction)
        #expect(snapshot.schema.rowMatchExcludedTypePrefixes.contains("ARRAY"))
    }

    @Test("MariaDB still takes the plugin's type list, since its curated list states nothing of its own")
    func mariadbTakesPluginTypes() throws {
        let registry = PluginMetadataRegistry.shared
        var plugin = try Self.mysqlPluginSnapshot()
        plugin.editor = PluginMetadataSnapshot.EditorConfig(
            sqlDialect: plugin.editor.sqlDialect,
            statementCompletions: [],
            columnTypesByCategory: ["Integer": ["INT"]]
        )
        registry.registerVariant(pluginSnapshot: plugin, forTypeId: "MariaDB", primaryTypeId: "MySQL")
        #expect(registry.snapshot(forRegisteredTypeId: "MariaDB")?.editor.columnTypesByCategory == ["Integer": ["INT"]])
        registry.registerVariant(pluginSnapshot: try Self.mysqlPluginSnapshot(), forTypeId: "MariaDB", primaryTypeId: "MySQL")
    }

    @Test("TiDB hides the connection limit it ignores; the others keep it")
    func principalConnectionLimit() {
        #expect(!PluginManager.shared.supportsPrincipalConnectionLimit(for: .tidb))
        #expect(PluginManager.shared.supportsPrincipalConnectionLimit(for: .mysql))
        #expect(PluginManager.shared.supportsPrincipalConnectionLimit(for: .mariadb))
    }

    @Test("Only Databend leaves column types out of a keyless row match")
    func rowMatchExclusions() {
        #expect(PluginManager.shared.rowMatchExcludedTypePrefixes(for: .databend).contains("VARIANT"))
        #expect(PluginManager.shared.rowMatchExcludedTypePrefixes(for: .mysql).isEmpty)
        #expect(PluginManager.shared.rowMatchExcludedTypePrefixes(for: .tidb).isEmpty)
    }

    @Test("Every MySQL-family engine matches a keyless row on the text of the types that cannot compare")
    func mysqlFamilyMatchesLossyTypesAsText() {
        for type in [DatabaseType.mysql, .mariadb, .tidb] {
            let prefixes = PluginManager.shared.rowMatchTextTypePrefixes(for: type)
            #expect(prefixes.contains("FLOAT"))
            #expect(prefixes.contains("DOUBLE"))
            #expect(prefixes.contains("JSON"))
            #expect(!prefixes.contains("BIT"))
        }
        #expect(PluginManager.shared.rowMatchTextTypePrefixes(for: .postgresql).isEmpty)
        #expect(PluginManager.shared.rowMatchTextTypePrefixes(for: .sqlite).isEmpty)
    }

    @Test("The inspector's function menu offers only what each engine has")
    func functionMenu() {
        let tidb = SQLFunctionProvider.functions(for: .tidb).map(\.expression)
        #expect(tidb.contains("CURDATE()"))
        #expect(tidb.contains("UTC_TIMESTAMP()"))
        let databend = SQLFunctionProvider.functions(for: .databend).map(\.expression)
        #expect(databend == ["NOW()", "CURRENT_TIMESTAMP()", "UUID()"])
    }

    @Test("A double-quoted name is a string on TiDB and an identifier on Databend")
    func fingerprintDoubleQuotes() {
        let orders = "SELECT * FROM \"orders\""
        let customers = "SELECT * FROM \"customers\""
        #expect(SQLQueryFingerprint.hash(orders, databaseType: .tidb) == SQLQueryFingerprint.hash(customers, databaseType: .tidb))
        #expect(SQLQueryFingerprint.hash(orders, databaseType: .databend) != SQLQueryFingerprint.hash(customers, databaseType: .databend))
    }

    @Test("Databend lexes as the generic dialect, TiDB as MySQL")
    func lexicalDialects() {
        #expect(SqlDialect.from(databaseTypeId: "TiDB") == .mysql)
        #expect(SqlDialect.from(databaseTypeId: "Databend") == .generic)
    }

    @Test("TiDB foreign keys offer no SET DEFAULT, which TiDB treats as RESTRICT")
    func tidbForeignKeyActions() {
        let dialect = ForeignKeyDialect.forType(.tidb)
        #expect(dialect == ForeignKeyDialect.forType(.mysql))
    }

    @Test("TiDB copies as the MySQL type family; Databend does not")
    func typeFamilies() {
        #expect(SQLTypeFamily.of(.tidb) == .mysql)
        #expect(!SQLTypeFamily.needsTranslation(from: .mysql, to: .tidb))
        #expect(SQLTypeFamily.of(.databend) != .mysql)
    }

    @Test("TiDB offers MySQL's default expressions")
    func tidbDefaultExpressions() {
        #expect(ColumnDefaultVocabulary.options(for: .tidb) == ColumnDefaultVocabulary.options(for: .mysql))
    }

    @Test("Neither variant gets a Server Dashboard or a native backup")
    func dashboardAndBackup() {
        #expect(ServerDashboardQueryProviderFactory.provider(for: .tidb) == nil)
        #expect(ServerDashboardQueryProviderFactory.provider(for: .databend) == nil)
        #expect(!NativeDumpRegistry.supports(.tidb))
        #expect(!NativeDumpRegistry.supports(.databend))
    }

    @Test("TiDB compares with TiDB, not with MySQL or MariaDB")
    func comparePairs() {
        #expect(CompareSyncEngineFamily.canGenerateStructureScript(from: .tidb, to: .tidb))
        #expect(!CompareSyncEngineFamily.canGenerateStructureScript(from: .mysql, to: .tidb))
        #expect(!CompareSyncEngineFamily.canGenerateStructureScript(from: .tidb, to: .mariadb))
        #expect(!CompareSyncEngineFamily.canGenerateStructureScript(from: .mysql, to: .databend))
    }

    @Test("URLs: tidb:// opens TiDB, databend:// is refused")
    func urlSchemes() {
        guard case .success(let tidb) = ConnectionURLParser.parse("tidb://root@host:4000/test") else {
            Issue.record("Expected tidb:// to parse"); return
        }
        #expect(tidb.type == .tidb)
        guard case .failure = ConnectionURLParser.parse("databend://root:pw@host:8000/default") else {
            Issue.record("Expected databend:// to be refused"); return
        }
    }
}
