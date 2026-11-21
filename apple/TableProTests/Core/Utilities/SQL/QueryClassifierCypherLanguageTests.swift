//
//  QueryClassifierCypherLanguageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSQLGrammar
import Testing

// A registry plugin for a graph engine other than Neo4j declares Cypher as its editor language.
struct QueryClassifierCypherLanguageTests {
    private func registerEngine(language: EditorLanguage) -> DatabaseType {
        let typeId = "CypherLanguageFake-\(UUID().uuidString)"
        let snapshot = PluginMetadataSnapshot(
            displayName: typeId, iconName: "cylinder", defaultPort: 7_687,
            requiresAuthentication: true, supportsForeignKeys: false, supportsSchemaEditing: false,
            isDownloadable: true, primaryUrlScheme: "cypherlanguagefake", parameterStyle: .dollar,
            navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
            supportsHealthMonitor: false, urlSchemes: [], postConnectActions: [],
            brandColorHex: "#000000", queryLanguageName: "Cypher", editorLanguage: language,
            connectionMode: .network, supportsDatabaseSwitching: true,
            capabilities: .defaults, schema: .defaults, editor: .defaults, connection: .defaults
        )
        PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: typeId)
        return DatabaseType(rawValue: typeId)
    }

    private func unregister(_ type: DatabaseType) {
        PluginMetadataRegistry.shared.unregister(typeId: type.rawValue)
    }

    @Test("Cypher reads are reads on any engine that declares Cypher", arguments: [
        "MATCH (n:Person) RETURN n LIMIT 25",
        "MATCH (a)--(b) RETURN a, b",
        "OPTIONAL MATCH (n)-[r]->(m) RETURN n, r, m",
        "CALL db.labels()",
    ])
    func readsAreReads(query: String) {
        let type = registerEngine(language: .custom("cypher"))
        defer { unregister(type) }

        #expect(QueryClassifier.classifyTier(query, databaseType: type) == .safe)
        #expect(!QueryClassifier.isWriteQuery(query, databaseType: type))
        #expect(QueryClassifier.isDataStatement(query, databaseType: type))
        #expect(CatalogChangeClassifier.effect(of: query, databaseType: type) == .none)
    }

    @Test("Cypher writes are tiered as they are on Neo4j")
    func writesAreTieredAsOnNeo4j() {
        let type = registerEngine(language: .custom("cypher"))
        defer { unregister(type) }

        for query in ["MATCH (n) SET n.seen = true", "CREATE (n:Person {id: 1})", "DROP DATABASE sales"] {
            #expect(
                QueryClassifier.classifyTier(query, databaseType: type)
                    == QueryClassifier.classifyTier(query, databaseType: .neo4j),
                "\(query)"
            )
        }
        #expect(CatalogChangeClassifier.effect(of: "CREATE (n:Person)", databaseType: type) == .opaque)
        #expect(!QueryClassifier.isDataStatement("CREATE INDEX FOR (n:Person) ON (n.id)", databaseType: type))
    }

    @Test("An unfiltered Cypher delete is dangerous and a filtered one is not")
    func unfilteredDeleteIsDangerous() {
        let type = registerEngine(language: .custom("cypher"))
        defer { unregister(type) }

        #expect(QueryClassifier.isDangerousQuery("MATCH (n) DETACH DELETE n", databaseType: type))
        #expect(!QueryClassifier.isDangerousQuery("MATCH (n) WHERE n.id = 1 DELETE n", databaseType: type))
    }

    @Test("A Cypher engine is split as Neo4j is, so `--` in a pattern is no comment")
    func lexesAsNeo4j() {
        let type = registerEngine(language: .custom("cypher"))
        defer { unregister(type) }

        #expect(type.lexicalReadings == DatabaseType.neo4j.lexicalReadings)
        let script = "MATCH (a)--(b) RETURN a; MATCH (c) RETURN c"
        #expect(QueryClassifier.statements(of: script, grammar: type.lexicalGrammar).count == 2)
    }

    @Test("The same text on an engine that declares SQL takes the SQL reading")
    func sqlEngineIsNotReadAsCypher() {
        let type = registerEngine(language: .sql)
        defer { unregister(type) }

        #expect(QueryClassifier.classifyTier("MATCH (n:Person) RETURN n", databaseType: type) == .write)
    }
}
