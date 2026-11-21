//
//  QueryClassifier+Etcd.swift
//  TablePro
//

import Foundation
import TableProSQLGrammar

extension QueryClassifier {
    static func etcdClassification(_ trimmed: String) -> QueryClassification {
        // Grid browse (ETCD_RANGE), exact count (ETCD_COUNT) and the driver's own refusal marker
        // (ETCD_REFUSAL, surfaced as a real error at execution) only read.
        if trimmed.hasPrefix("ETCD_RANGE:") || trimmed.hasPrefix("ETCD_COUNT:")
            || trimmed.hasPrefix("ETCD_REFUSAL:") {
            return .safe
        }
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
