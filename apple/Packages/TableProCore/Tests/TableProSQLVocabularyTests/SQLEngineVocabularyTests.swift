import Foundation
import TableProPluginKit
import TableProSQLVocabulary
import Testing

struct SQLEngineVocabularyTests {
    @Test("Every engine the table covers offers functions and data types")
    func everyEngineHasVocabulary() {
        let typeIds = SQLEngineVocabulary.curatedDatabaseTypeIds
        #expect(typeIds == [
            "MySQL", "MariaDB", "TiDB", "Databend", "OceanBase",
            "PostgreSQL", "CockroachDB", "PGlite", "KingbaseES", "Redshift",
            "SQLite", "SQL Server", "Oracle", "DuckDB",
        ])
        for typeId in typeIds {
            let vocabulary = SQLEngineVocabulary.curated(forDatabaseTypeId: typeId)
            #expect(vocabulary?.functions.isEmpty == false, "\(typeId)")
            #expect(vocabulary?.dataTypes.isEmpty == false, "\(typeId)")
        }
    }

    @Test("An engine the table does not cover has no vocabulary")
    func unknownEngine() {
        #expect(SQLEngineVocabulary.curated(forDatabaseTypeId: "ClickHouse") == nil)
        #expect(SQLEngineVocabulary.curated(forDatabaseTypeId: "postgresql") == nil)
    }

    @Test("A variant id resolves to its base engine's vocabulary", arguments: [
        ("MariaDB", "MySQL"),
        ("TiDB", "MySQL"),
        ("Databend", "MySQL"),
        ("OceanBase", "MySQL"),
        ("CockroachDB", "PostgreSQL"),
        ("PGlite", "PostgreSQL"),
        ("KingbaseES", "PostgreSQL"),
    ])
    func variantResolvesLikeItsBase(variant: String, base: String) {
        let resolved = SQLEngineVocabulary.curated(forDatabaseTypeId: variant)
        #expect(resolved != nil)
        #expect(resolved == SQLEngineVocabulary.curated(forDatabaseTypeId: base))
    }

    @Test("Redshift keeps its own shorter list instead of PostgreSQL's")
    func redshiftKeepsItsOwnList() throws {
        let redshift = try #require(SQLEngineVocabulary.curated(forDatabaseTypeId: "Redshift"))
        let postgreSQL = try #require(SQLEngineVocabulary.curated(forDatabaseTypeId: "PostgreSQL"))
        #expect(redshift != postgreSQL)
        #expect(!redshift.functions.contains("JSONB_PATH_QUERY"))
        #expect(redshift.operators.isEmpty)
    }

    @Test("PostgreSQL carries the plugin's functions, data types and operators")
    func postgreSQLCarriesThePluginLists() throws {
        let vocabulary = try #require(SQLEngineVocabulary.curated(forDatabaseTypeId: "PostgreSQL"))
        #expect(vocabulary.functions.isSuperset(of: ["JSONB_PATH_QUERY", "GEN_RANDOM_UUID", "TS_RANK", "DATE_BIN"]))
        #expect(vocabulary.dataTypes.isSuperset(of: ["JSONB", "TSTZMULTIRANGE", "DOUBLE PRECISION", "PG_LSN"]))
        #expect(vocabulary.operators.count == 55)

        let symbols = Set(vocabulary.operators.map(\.symbol))
        #expect(symbols.isSuperset(of: ["::", "->>", "#>>", "@>", "?|", "&&", "-|-", "<->", "<<=", "IS DISTINCT FROM"]))

        let isNull = try #require(vocabulary.operators.first { $0.symbol == "IS NULL" })
        #expect(isNull.category == "predicate")
        #expect(isNull.placement == "postfix")

        let arrow = try #require(vocabulary.operators.first { $0.symbol == "->>" })
        #expect(arrow.appliesToTypes == ["json", "jsonb"])
    }

    @Test("Every operator names a category and placement PluginKit knows, or a plugin drops it")
    func operatorRawValuesMatchPluginKit() {
        for typeId in SQLEngineVocabulary.curatedDatabaseTypeIds {
            for entry in SQLEngineVocabulary.curated(forDatabaseTypeId: typeId)?.operators ?? [] {
                #expect(SQLOperatorDescriptor.Category(rawValue: entry.category) != nil, "\(typeId) \(entry.symbol)")
                #expect(SQLOperatorDescriptor.Placement(rawValue: entry.placement) != nil, "\(typeId) \(entry.symbol)")
            }
        }
    }

    @Test("Oracle completes exactly the types its column type picker groups")
    func oracleTypesMatchThePickerGroups() {
        let grouped = SQLEngineVocabulary.oracleDataTypeCategories.flatMap(\.types)
        #expect(SQLEngineVocabulary.oracle.dataTypes == Set(grouped))
        #expect(grouped.count == Set(grouped).count)
    }
}
