//
//  QueryClassifier+Etcd.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

extension QueryClassifier {
    static func etcdClassification(_ trimmed: String) -> QueryClassification {
        guard let operation = try? EtcdCommandParser.parse(trimmed) else {
            return etcdUnparsedClassification(command: EtcdCommandParser.commandName(trimmed) ?? "")
        }
        return etcdClassification(of: operation)
    }

    private static let etcdCommandsThatCanDestroy: Set<String> = [
        "del", "delete", "compaction", "compact", "lease", "member", "auth", "user", "role"
    ]

    private static let etcdCommandsReachingFilesystem: Set<String> = ["snapshot", "defrag"]

    private static func etcdClassification(of operation: EtcdOperation) -> QueryClassification {
        if case .unknown(let command, _) = operation {
            return etcdUnparsedClassification(command: command)
        }
        switch operation.tier {
        case .read:
            return .safe
        case .write, nil:
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        case .destructive:
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)
        }
    }

    private static func etcdUnparsedClassification(command: String) -> QueryClassification {
        let reachesFilesystem = etcdCommandsReachingFilesystem.contains(command)
        let tier: QueryTier = etcdCommandsThatCanDestroy.contains(command) ? .destructive : .write
        return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: reachesFilesystem)
    }
}
