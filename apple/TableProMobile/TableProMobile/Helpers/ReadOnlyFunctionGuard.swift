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

    static let callableCatalog = SQLCallableCatalogCache()

    // Oracle calls a function named without parentheses once the name is not a column in scope, so the session's own
    // catalog says which names call. A catalog that cannot be read leaves the name unexplained, and it counts as a call.
    static func refusesBareName(
        _ sql: String,
        databaseType: DatabaseType,
        level: SafeModeLevel,
        connectionId: UUID,
        schema: String?,
        read: @escaping SQLCallableCatalogCache.Reader
    ) async -> Bool {
        let typeId = databaseType.rawValue
        guard level.blocksWrites, SQLBareNameCalls.engines.contains(typeId) else { return false }
        let reading = SQLBareNameCalls.read(
            sql,
            databaseTypeId: typeId,
            readings: SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil)
        )
        guard !reading.namesNothing else { return false }
        let calls = try? await callableCatalog.callsFunction(
            reading, connectionId: connectionId, schema: schema, read: read
        )
        return calls ?? true
    }
}
