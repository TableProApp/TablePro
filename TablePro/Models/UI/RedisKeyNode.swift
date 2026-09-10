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

    var children: [RedisKeyNode]? {
        switch self {
        case .namespace(_, _, let children, _): return children
        case .key: return nil
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

extension RedisKeyNode {
    /// Lifted out of the sidebar view so the outline row and anything else that renders a key can
    /// agree on the glyph without importing SwiftUI.
    static func iconName(forKeyType type: String) -> String {
        switch type.lowercased() {
        case "string": return "textformat"
        case "hash": return "square.grid.2x2"
        case "list": return "list.bullet"
        case "set": return "circle.grid.3x3"
        case "zset": return "chart.bar"
        case "stream": return "waveform"
        default: return "key"
        }
    }
}
