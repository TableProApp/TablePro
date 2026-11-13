import Foundation
import TableProDatabase
import TableProModels
import TableProSQLGrammar
import TableProSQLVocabulary

// In the engine's read-only mode the server refuses what a function writes inside the transaction. Without it, at
// Read-Only a call off the built-in list, on an engine whose functions can write, cannot be told from a write and is
// refused like one.
nonisolated enum ReadOnlyFunctionGuard {
    static func refuses(
        _ sql: String,
        databaseType: DatabaseType,
        level: SafeModeLevel,
        enforcesReadOnlyMode: Bool
    ) -> Bool {
        let typeId = databaseType.rawValue
        guard level.blocksWrites, !enforcesReadOnlyMode,
              SQLReadOnlyFunctionCalls.queryFunctionsCanWrite.contains(typeId) else { return false }
        return SQLReadOnlyFunctionCalls.callsUnlistedFunction(
            sql,
            databaseTypeId: typeId,
            readings: SQLLexicalReadings.resolve(databaseTypeId: typeId, declared: nil, session: nil),
            typeNames: SQLEngineVocabulary.curated(forDatabaseTypeId: typeId)?.dataTypes ?? []
        )
    }

    // A write never reaches the driver at Read-Only, so only a read asks the session. One holding a transaction or a
    // table lock runs as it is, and MySQL with autocommit off always holds a transaction.
    static func runsInReadOnlyMode(writes: Bool, level: SafeModeLevel, driver: any DatabaseDriver) async -> Bool {
        guard !writes, level.blocksWrites else { return false }
        return await driver.entersReadOnlyMode()
    }
}
