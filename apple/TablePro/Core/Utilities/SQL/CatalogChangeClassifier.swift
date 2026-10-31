//
//  CatalogChangeClassifier.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

// SQL is read by SQLCatalogEffectClassifier, shared with iOS; engines that do not speak SQL are decided here.
enum CatalogChangeClassifier {
    static func effect(
        ofStatements statements: [String],
        databaseType: DatabaseType,
        grammar: SQLLexicalGrammar? = nil
    ) -> SQLCatalogEffect {
        statements.reduce(SQLCatalogEffect.none) { partial, statement in
            partial.union(effect(of: statement, databaseType: databaseType, grammar: grammar))
        }
    }

    static func effect(
        of sql: String,
        databaseType: DatabaseType,
        grammar: SQLLexicalGrammar? = nil
    ) -> SQLCatalogEffect {
        let resolvedGrammar = grammar ?? databaseType.lexicalGrammar
        let trimmed = StatementBlank.trimming(SQLLeadingComments.stripping(sql, grammar: resolvedGrammar))
        guard !trimmed.isEmpty else { return .none }
        if databaseType == .redis {
            return .none
        }
        if documentStoreTypes.contains(databaseType) {
            let tier = QueryClassifier.classifyTier(trimmed, databaseType: databaseType)
            return tier == .safe ? .none : .opaque
        }
        if let request = dynamoDBRequestEffect(trimmed, grammar: resolvedGrammar, databaseType: databaseType) {
            return request
        }
        return SQLCatalogEffectClassifier.effect(of: trimmed, grammar: resolvedGrammar)
    }

    // PartiQL, and an action the driver does not know, which goes out as PartiQL, take the SQL path.
    private static func dynamoDBRequestEffect(
        _ trimmed: String,
        grammar: SQLLexicalGrammar,
        databaseType: DatabaseType
    ) -> SQLCatalogEffect? {
        guard databaseType == .dynamodb,
              let action = DynamoDBRequestStatement(trimmed, grammar: grammar)?.action
        else { return nil }
        return action.changesCatalog ? SQLCatalogEffect(kinds: .tables, endsTransaction: false) : .none
    }

    private static let documentStoreTypes: Set<DatabaseType> = [
        .mongodb, .elasticsearch, .typesense, .weaviate, .etcd, .firestore, .firebaseRealtimeDatabase, .bigtable, .neo4j
    ]
}
