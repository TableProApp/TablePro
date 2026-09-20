//
//  EtcdGatewayRoute.swift
//  EtcdDriverPlugin
//
//  Decides whether an etcd v3 gateway prefix is routed, from the answer alone.
//

import Foundation

internal enum EtcdGatewayRoute: Equatable, Sendable {
    case routed
    case notRouted
    case notEtcd
}

internal extension EtcdGatewayRoute {
    static let candidatePrefixes = ["v3", "v3beta", "v3alpha"]

    static func classify(httpStatus: Int, body: Data) -> EtcdGatewayRoute {
        guard httpStatus != notFoundStatus else { return .notRouted }
        guard isJsonObject(body) else { return .notEtcd }
        return .routed
    }
}

private extension EtcdGatewayRoute {
    static let notFoundStatus = 404

    static func isJsonObject(_ body: Data) -> Bool {
        guard !body.isEmpty else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: body) else { return false }
        return object is [String: Any]
    }
}
