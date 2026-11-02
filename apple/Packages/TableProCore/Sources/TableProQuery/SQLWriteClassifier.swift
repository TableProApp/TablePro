import Foundation
import TableProModels
import TableProPluginKit
import TableProRedisCore
import TableProSQLGrammar

/// Decides whether a statement batch writes, so Safe Mode can block or confirm it. Redis and MongoDB are read the way
/// their drivers read them; SQL is tiered by ``SQLStatementClassifier``, the classifier the Mac shares.
public enum SQLWriteClassifier {
    public static func isWriteQuery(_ sql: String, databaseType: DatabaseType) -> Bool {
        if databaseType == .redis {
            return RedisCommandSplitter.commands(in: sql).contains { redisWrites($0.text) }
        }
        if databaseType == .mongodb {
            let verdict = MongoStatementClassifier.verdict(
                sql, shadowsCollection: MongoCollectionAccessor.isShadowedByDatabaseMember
            )
            return verdict.tier != .read
        }
        let readings = SQLLexicalReadings.resolve(databaseTypeId: databaseType.rawValue, declared: nil, session: nil)
        return SQLStatementClassifier.isWrite(sql, databaseTypeId: databaseType.rawValue, readings: readings)
    }

    // Read as the driver reads it, so a quoted verb is the command that runs. Unparseable text counts as a write.
    private static func redisWrites(_ command: String) -> Bool {
        guard let arguments = RedisArgumentCodec.split(command) else { return true }
        let words = arguments.map { String(bytes: $0, encoding: .utf8) ?? "" }
        return !RedisReadCommands.onlyReads(words[...])
    }
}
