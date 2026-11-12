import Foundation
import TableProModels
import TableProSQLGrammar
import TableProSQLVocabulary

// No iOS driver runs a read in the engine's read-only mode, so at Read-Only a call off the built-in list, on an engine
// whose functions can write, cannot be told from a write and is refused like one.
nonisolated enum ReadOnlyFunctionGuard {
    static func refuses(_ sql: String, databaseType: DatabaseType, level: SafeModeLevel) -> Bool {
        let typeId = databaseType.rawValue
        guard level.blocksWrites, SQLReadOnlyFunctionCalls.queryFunctionsCanWrite.contains(typeId) else { return false }
        return SQLReadOnlyFunctionCalls.callsUnlistedFunction(
            sql,
            databaseTypeId: typeId,
            readings: SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil),
            typeNames: SQLEngineVocabulary.curated(forDatabaseTypeId: typeId)?.dataTypes ?? []
        )
    }
}
