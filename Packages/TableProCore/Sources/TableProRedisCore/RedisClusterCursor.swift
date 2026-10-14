//
//  RedisClusterCursor.swift
//  RedisDriverPlugin
//
//  SCAN across a cluster walks each master in turn, so the cursor has to say which node it
//  belongs to as well as where that node got to.
//
//  It names the node by cluster id rather than by position in a list. A node index would be
//  silently wrong the moment the topology changed: Redis accepts another node's cursor without
//  complaint and answers with a plausible-looking page, so a slipped index loses keys with no
//  error anywhere. An id that is no longer in the topology is detectable, and restarts that node.
//

import Foundation

enum RedisClusterCursor {
    /// The value both Redis and the driver use for "start here" and for "nothing left".
    static let start = "0"

    enum Position: Equatable {
        /// Every node has been walked.
        case finished
        /// Scan `id`, resuming at `cursor`. `restarted` means the cursor named a node the topology
        /// no longer has, so this node begins again and the result is incomplete.
        case node(id: String, cursor: String, restarted: Bool)
    }

    static func encode(nodeId: String, nodeCursor: String) -> String {
        "\(nodeId)-\(nodeCursor)"
    }

    static func decode(_ raw: String, orderedNodeIds: [String]) -> Position {
        guard let firstNode = orderedNodeIds.first else { return .finished }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != start else {
            return .node(id: firstNode, cursor: start, restarted: false)
        }
        // The node id falls back to "host:port" when the server reports none, and a hostname can
        // contain a hyphen, so the split has to come from the right: the cursor never does.
        guard let separator = trimmed.lastIndex(of: "-") else {
            return .node(id: firstNode, cursor: start, restarted: true)
        }
        let nodeId = String(trimmed[..<separator])
        let nodeCursor = String(trimmed[trimmed.index(after: separator)...])
        guard orderedNodeIds.contains(nodeId), !nodeCursor.isEmpty else {
            return .node(id: firstNode, cursor: start, restarted: true)
        }
        return .node(id: nodeId, cursor: nodeCursor, restarted: false)
    }

    /// The cursor to hand back once `nodeId` has answered with `nodeCursor`. A node that reports
    /// `0` has finished its own iteration, so the walk moves to the next one; running out of nodes
    /// ends the scan.
    static func advance(after nodeId: String, nodeCursor: String, orderedNodeIds: [String]) -> String {
        guard nodeCursor == start else { return encode(nodeId: nodeId, nodeCursor: nodeCursor) }
        guard let index = orderedNodeIds.firstIndex(of: nodeId), index + 1 < orderedNodeIds.count else {
            return start
        }
        return encode(nodeId: orderedNodeIds[index + 1], nodeCursor: start)
    }
}
