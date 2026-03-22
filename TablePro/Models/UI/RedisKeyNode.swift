//
//  RedisKeyNode.swift
//  TablePro
//

import Foundation

internal enum RedisKeyNode: Identifiable, Hashable {
    case namespace(name: String, fullPrefix: String, children: [RedisKeyNode], keyCount: Int)
    case key(name: String, fullKey: String, keyType: String)

    var id: String {
        switch self {
        case .namespace(_, let fullPrefix, _, _): return "ns:\(fullPrefix)"
        case .key(_, let fullKey, _): return "key:\(fullKey)"
        }
    }

    var displayName: String {
        switch self {
        case .namespace(let name, _, _, _): return name
        case .key(let name, _, _): return name
        }
    }

    // Hash on id only (children excluded for performance)
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: RedisKeyNode, rhs: RedisKeyNode) -> Bool {
        lhs.id == rhs.id
    }
}
