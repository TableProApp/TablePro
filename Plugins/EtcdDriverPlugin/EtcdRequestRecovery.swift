//
//  EtcdRequestRecovery.swift
//  EtcdDriverPlugin
//
//  Decides what a failed etcd request should do next, the way clientv3 does.
//

import Foundation

internal enum EtcdRequestRecovery: Equatable, Sendable {
    case reauthenticateAndRetry
    case surface
}

internal extension EtcdRequestRecovery {
    static func action(
        for fault: EtcdServerFault,
        hasCredentials: Bool,
        isRetry: Bool
    ) -> EtcdRequestRecovery {
        guard !isRetry, hasCredentials else { return .surface }
        switch fault.kind {
        case .credentialsRequired, .tokenRejected, .authRevisionStale:
            return .reauthenticateAndRetry
        case .credentialsRejected, .authNotEnabled, .permissionDenied, .unclassified:
            return .surface
        }
    }
}

internal extension EtcdServerFault {
    var provesLiveSession: Bool {
        kind == .permissionDenied
    }
}
