import Foundation
import TableProModels
import TableProQuery
import TableProSQLGrammar

// The Mac's capped read (`QueryExecutor.qualifiesForRowCap`): one statement that only reads, so stopping it on the
// server at the row cap loses nothing but rows. Anything else, a `CALL` or a `DELETE ... RETURNING`, is read to its end
// so the work after its rows still happens.
nonisolated enum CappedRead {
    private static let rowProducingKeywords: Set<String> = ["SELECT", "WITH", "TABLE", "VALUES"]

    static func qualifies(_ sql: String, databaseType: DatabaseType, session: SQLSessionLexicalFacts? = nil) -> Bool {
        let grammar = SQLLexicalReadings.resolve(
            databaseTypeId: databaseType.rawValue, declared: nil, session: session
        ).execution
        let statements = SQLStatementClassifier.statements(of: sql, grammar: grammar)
        guard statements.count == 1, let statement = statements.first,
              let keyword = SQLStatementRowLimit.leadingKeyword(statement, grammar: grammar),
              rowProducingKeywords.contains(keyword)
        else { return false }
        return !SQLWriteClassifier.isWriteQuery(sql, databaseType: databaseType)
    }
}
