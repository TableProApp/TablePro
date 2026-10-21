import Foundation
@testable import TableProAutocomplete
import TableProSQLGrammar
import Testing

struct SQLCompletionVocabularyCuratedTests {
    @Test("An engine the table does not cover gets the generic vocabulary")
    func unknownEngineIsGeneric() {
        let vocabulary = SQLCompletionVocabulary.curated(forDatabaseTypeId: "ClickHouse")
        #expect(vocabulary.functions.isEmpty)
        #expect(vocabulary.dataTypes.isEmpty)
        #expect(vocabulary.operators.isEmpty)
        #expect(vocabulary.tableOptions == nil)
    }

    @Test("PostgreSQL brings its functions, data types, operators and table options")
    func postgreSQLVocabulary() throws {
        let vocabulary = SQLCompletionVocabulary.curated(forDatabaseTypeId: "PostgreSQL")
        #expect(vocabulary.functions.contains("JSONB_BUILD_OBJECT"))
        #expect(vocabulary.dataTypes.contains("TIMESTAMPTZ"))
        #expect(vocabulary.functionNamesAreCaseInsensitive)
        #expect(vocabulary.tableOptions?.contains("INHERITS") == true)

        let arrow = try #require(vocabulary.operators.first { $0.symbol == "->>" })
        #expect(arrow.summary == "Extracts JSON object field or array element, as text")
        #expect(arrow.appliesToTypes == ["json", "jsonb"])
    }

    @Test("An engine with no table options offers none rather than the generic ones")
    func emptyTableOptionsStayEmpty() {
        #expect(SQLCompletionVocabulary.curated(forDatabaseTypeId: "DuckDB").tableOptions?.isEmpty == true)
    }

    @Test("A variant id gets its base engine's vocabulary")
    func variantMatchesItsBase() {
        let mariaDB = SQLCompletionVocabulary.curated(forDatabaseTypeId: "MariaDB")
        let mySQL = SQLCompletionVocabulary.curated(forDatabaseTypeId: "MySQL")
        #expect(!mariaDB.functions.isEmpty)
        #expect(mariaDB.functions == mySQL.functions)
        #expect(mariaDB.dataTypes == mySQL.dataTypes)
        #expect(mariaDB.tableOptions == mySQL.tableOptions)
    }

    @Test("The editor offers an engine function only with that engine's vocabulary")
    func providerOffersEngineFunctions() async {
        let text = "SELECT jsonb_build_o"
        let curated = SQLCompletionProvider(
            catalog: nil,
            grammar: .engine("PostgreSQL"),
            vocabulary: .curated(forDatabaseTypeId: "PostgreSQL")
        )
        let generic = SQLCompletionProvider(catalog: nil, grammar: .engine("PostgreSQL"), vocabulary: .generic)

        let offered = await curated.getCompletions(text: text, cursorPosition: text.utf16.count).items
        let offeredGeneric = await generic.getCompletions(text: text, cursorPosition: text.utf16.count).items

        #expect(offered.contains { $0.kind == .function && $0.label.uppercased() == "JSONB_BUILD_OBJECT" })
        #expect(!offeredGeneric.contains { $0.label.uppercased() == "JSONB_BUILD_OBJECT" })
    }
}
