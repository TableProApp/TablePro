//
//  EtcdLeaseID.swift
//  EtcdDriverPlugin
//

import Foundation

internal enum EtcdLeaseID {
    static func cellText(serverValue: String?) -> String {
        guard let serverValue, serverValue != "0" else { return "" }
        guard let leaseId = Int64(serverValue) else { return serverValue }
        return hexText(leaseId)
    }

    static func hexText(serverValue: String) -> String {
        guard let leaseId = Int64(serverValue) else { return serverValue }
        return hexText(leaseId)
    }

    static func hexText(_ leaseId: Int64) -> String {
        "0x" + String(leaseId, radix: 16)
    }
}
