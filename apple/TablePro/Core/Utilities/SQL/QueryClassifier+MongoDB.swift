//
//  QueryClassifier+MongoDB.swift
//  TablePro
//

import Foundation
import TableProPluginKit
import TableProSQLGrammar

extension QueryClassifier {
    static func mongoClassification(_ text: String) -> QueryClassification {
        let verdict = MongoStatementClassifier.verdict(
            text, shadowsCollection: MongoCollectionAccessor.isShadowedByDatabaseMember
        )
        return QueryClassification(tier: queryTier(of: verdict.tier), reachesFilesystemOrExecutesCode: verdict.reachesCode)
    }

    // Their reads hold though the driver declares no read-only mode: MongoDB, Redis and etcd classify their own
    // language and call anything not proven a read a write, and SAP HANA is SQL, read as every SQL engine is.
    // Neo4j is here so its driver opens a proven read in Bolt's read mode, where the server refuses a write.
    static let enginesWithProvenReads: Set<DatabaseType> = [.mongodb, .redis, .etcd, .sapHana, .neo4j]

    // Only text the grammar accepts can be named: anything else may reach any method once JavaScript runs it.
    static func mongoDataCommands(_ text: String, systemDatabases: Set<String>) -> [DataCommand]? {
        let text = StatementBlank.trimming(text)
        let located = JavaScriptStatementScanner.locatedStatements(in: text)
        let statements = located.count > 1 ? located.map(\.text) : [text]
        let systemDatabases = Set(systemDatabases.map { $0.lowercased() })
        var commands: [DataCommand] = []
        for statement in statements where !MongoStatementParser.isTrivia(statement) {
            guard let parsed = MongoStatementParser.parse(
                statement, shadowsCollection: MongoCollectionAccessor.isShadowedByDatabaseMember
            ) else { return nil }
            // `$out` and `$merge` write to a collection the pipeline names, and server-side JavaScript to any.
            guard !mongoClassification(statement).reachesFilesystemOrExecutesCode else { return [.refused] }
            commands += parsed.calls.map { mongoDataCommand($0, systemDatabases: systemDatabases) }
        }
        return commands.isEmpty ? [.read] : commands
    }

    private static func mongoDataCommand(_ call: MongoStatement.Call, systemDatabases: Set<String>) -> DataCommand {
        // `use` moves the driver's database for every later statement.
        if call.receiver == .shell, call.name == "use" { return .refused }
        if call.isRead { return .read }
        let name: String
        switch call.receiver {
        case .collection:
            name = "db.collection.\(call.name)"
        case .database where call.name == "runCommand":
            // A read the command form sends; the code check above already refused `$out`, `$merge` and `$where`.
            if let command = call.commandName, MongoCommandCatalog.readsOnly(command) { return .read }
            guard let command = call.commandName, call.collection != nil else { return .refused }
            name = command
        default:
            // `adminCommand` and the database helpers create, kill or administer: none of them is a data change.
            return .refused
        }
        if let database = call.database, systemDatabases.contains(database.lowercased()) { return .refused }
        if let collection = call.collection, collection.lowercased().hasPrefix("system.") { return .refused }
        return .named(name)
    }

    private static func queryTier(of tier: MongoStatementTier) -> QueryTier {
        switch tier {
        case .read: return .safe
        case .write: return .write
        case .destructive: return .destructive
        }
    }
}
