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
    static let enginesWithProvenReads: Set<DatabaseType> = [.mongodb, .redis, .etcd, .sapHana]

    private static func queryTier(of tier: MongoStatementTier) -> QueryTier {
        switch tier {
        case .read: return .safe
        case .write: return .write
        case .destructive: return .destructive
        }
    }
}
