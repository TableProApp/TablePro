//
//  WorkspaceRailOrdering.swift
//  TablePro
//

import Foundation

internal enum WorkspaceRailOrdering {
    /// Workspaces the user has arranged keep that arrangement; the rest append in the order
    /// their connection opened, and within one connection by container name. A connection
    /// whose window exists before its session does has no timestamp yet and sorts last, so
    /// it appears at the bottom while connecting and stays there once its session lands,
    /// rather than showing up on top and then jumping.
    internal static func ranked(
        openIds: Set<WorkspaceID>,
        storedOrder: [WorkspaceID],
        openedAt: [UUID: Date]
    ) -> [WorkspaceID] {
        var placed: Set<WorkspaceID> = []
        var result: [WorkspaceID] = []

        for id in storedOrder {
            guard openIds.contains(id), placed.insert(id).inserted else { continue }
            result.append(id)
        }

        let newcomers = openIds.subtracting(placed).sorted { lhs, rhs in
            let left = openedAt[lhs.connectionId] ?? .distantFuture
            let right = openedAt[rhs.connectionId] ?? .distantFuture
            guard left == right else { return left < right }
            guard lhs.connectionId == rhs.connectionId else {
                return lhs.connectionId.uuidString < rhs.connectionId.uuidString
            }
            return lhs.container.localizedStandardCompare(rhs.container) == .orderedAscending
        }

        return result + newcomers
    }

    internal static func reordered(
        _ ids: [WorkspaceID],
        moving id: WorkspaceID,
        toRow row: Int
    ) -> [WorkspaceID] {
        guard let source = ids.firstIndex(of: id) else { return ids }

        var result = ids
        result.remove(at: source)

        let target = row > source ? row - 1 : row
        result.insert(id, at: min(max(target, 0), result.count))
        return result
    }

    internal static func cycled(
        in ids: [WorkspaceID],
        from current: WorkspaceID?,
        by offset: Int
    ) -> WorkspaceID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }

        let count = ids.count
        let destination = ((index + offset) % count + count) % count
        return ids[destination]
    }

    internal static func merged(
        visibleOrder: [WorkspaceID],
        into storedOrder: [WorkspaceID]
    ) -> [WorkspaceID] {
        let visible = Set(visibleOrder)
        var pending = visibleOrder[...]
        var result: [WorkspaceID] = []

        for id in storedOrder {
            guard visible.contains(id) else {
                result.append(id)
                continue
            }
            guard let next = pending.popFirst() else { continue }
            result.append(next)
        }

        return result + pending
    }
}
