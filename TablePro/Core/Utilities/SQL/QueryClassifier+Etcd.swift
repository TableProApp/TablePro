//
//  QueryClassifier+Etcd.swift
//  TablePro
//

import Foundation

extension QueryClassifier {
    static func etcdClassification(_ trimmed: String) -> QueryClassification {
        guard let operation = try? EtcdCommandParser.parse(trimmed) else {
            return etcdUnparsedClassification(command: EtcdCommandParser.tokenize(trimmed).first?.lowercased() ?? "")
        }
        return etcdClassification(of: operation)
    }

    private static let etcdCommandsThatCanDestroy: Set<String> = [
        "del", "delete", "compaction", "compact", "lease", "member", "auth", "user", "role"
    ]

    private static let etcdCommandsReachingFilesystem: Set<String> = ["snapshot", "defrag"]

    private static func etcdClassification(of operation: EtcdOperation) -> QueryClassification {
        switch operation {
        case .get, .watch, .leaseTimetolive, .leaseList, .memberList, .endpointStatus, .endpointHealth,
             .userList, .roleList:
            return .safe
        case .put, .leaseGrant, .leaseKeepAlive, .authEnable, .userAdd, .roleAdd, .userGrantRole, .userRevokeRole:
            return QueryClassification(tier: .write, reachesFilesystemOrExecutesCode: false)
        case .del, .compaction, .leaseRevoke, .authDisable, .userDelete, .roleDelete:
            return QueryClassification(tier: .destructive, reachesFilesystemOrExecutesCode: false)
        case .unknown(let command, _):
            return etcdUnparsedClassification(command: command)
        }
    }

    private static func etcdUnparsedClassification(command: String) -> QueryClassification {
        let reachesFilesystem = etcdCommandsReachingFilesystem.contains(command)
        let tier: QueryTier = etcdCommandsThatCanDestroy.contains(command) ? .destructive : .write
        return QueryClassification(tier: tier, reachesFilesystemOrExecutesCode: reachesFilesystem)
    }
}
