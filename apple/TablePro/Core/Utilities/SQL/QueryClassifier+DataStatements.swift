//
//  QueryClassifier+DataStatements.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

// One command as the assistant's Edit mode reads it.
enum DataCommand: Equatable, Sendable {
    // The gate's own tier reads it as a read.
    case read
    // Runs only when the engine's curated snapshot lists the name in `dataCommands`.
    case named(String)
    // Changes the engine's own state whatever its name, such as a write into a system collection.
    case refused
}

// Edit runs reads and changes to data, on every engine the rule SQL follows. The lists are allowlists, since each server
// release adds commands: a schema, privilege, session, transaction or server command, and any command a reader cannot
// name, is refused.
extension QueryClassifier {
    static func isDataStatement(_ sql: String, databaseType: DatabaseType) -> Bool {
        if let answer = isSQLDataStatement(sql, databaseType: databaseType) { return answer }
        let snapshot = PluginMetadataRegistry.shared.snapshot(for: databaseType)
        let listed = snapshot?.capabilities.dataCommands ?? []
        if databaseType == .surrealdb {
            return SQLStatementClassifier.isDataStatement(
                sql,
                databaseTypeId: databaseType.rawValue,
                readings: databaseType.lexicalReadings,
                rowChanges: listed
            )
        }
        guard let commands = dataCommands(of: sql, databaseType: databaseType, snapshot: snapshot) else { return false }
        return commands.allSatisfy { command in
            switch command {
            case .read: return true
            case .named(let name): return listed.contains(name)
            case .refused: return false
            }
        }
    }

    // Each command the text runs, read as the engine's driver reads it. Nil when the text cannot be read.
    static func dataCommands(
        of sql: String,
        databaseType: DatabaseType,
        snapshot: PluginMetadataSnapshot?
    ) -> [DataCommand]? {
        switch databaseType {
        case .redis:
            return redisDataCommands(sql)
        case .memcached:
            return memcachedDataCommands(sql, readings: databaseType.lexicalReadings)
        case .etcd:
            return etcdDataCommands(sql, readings: databaseType.lexicalReadings)
        case .kafka:
            return kafkaDataCommands(sql)
        case .mongodb:
            return mongoDataCommands(sql, systemDatabases: Set(snapshot?.schema.systemDatabaseNames ?? []))
        case .neo4j:
            return cypherDataCommands(sql)
        case .elasticsearch:
            return elasticsearchDataCommands(sql)
        case .typesense:
            return typesenseDataCommands(sql)
        case .qdrant:
            return qdrantDataCommands(sql)
        case .weaviate:
            return weaviateDataCommands(sql)
        case .firestore, .firebaseRealtimeDatabase:
            return firebaseDataCommands(sql, databaseType: databaseType)
        case .bigtable:
            return bigtableDataCommands(sql)
        default:
            // An engine no reader knows runs only what the gate reads as a read.
            return classify(sql, databaseType: databaseType).tier == .safe ? [.read] : nil
        }
    }

    // A write into the scope's database or schema when it is one the engine keeps its own state in. A table named
    // without a schema lands there. Engines curated with `dataCommands` name theirs in the snapshot.
    static func writesSystemScope(database: String?, schema: String?, databaseType: DatabaseType) -> Bool {
        if SQLStatementClassifier.isSystemScope(database: database, schema: schema, databaseTypeId: databaseType.rawValue) {
            return true
        }
        guard let snapshot = PluginMetadataRegistry.shared.snapshot(for: databaseType),
              snapshot.capabilities.dataCommands != nil, let database
        else { return false }
        return snapshot.schema.systemDatabaseNames.contains(database)
    }
}
