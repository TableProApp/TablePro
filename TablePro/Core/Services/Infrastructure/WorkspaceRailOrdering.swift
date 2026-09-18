//
//  WorkspaceRailOrdering.swift
//  TablePro
//

import Foundation

internal enum WorkspaceRailOrdering {
    /// Workspaces the user has arranged keep that arrangement; the rest append in the order
    /// their connection opened, and within one connection by container name.
    ///
    /// `openedAt` is when the connection joined the app, taken from its workspace, and it never
    /// moves: it is stamped before the connect and survives a disconnect, so an entry stays where it
    /// was through both. Taking it from the session instead meant a disconnect deleted the timestamp
    /// and sent the connection's entries to the bottom, where a reconnect could not put them back,
    /// because it minted a new session with a new one.
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

    /// How many arrangements are kept. A database that is renamed or dropped raises no event, so its
    /// entry can never be removed the way a deleted connection's is, and without a ceiling the
    /// stored order only grows. Everything open is kept whatever the count; the ceiling applies to
    /// the closed ones alone, oldest first, so a strip you are using is never trimmed.
    internal static let maxStoredEntries = 500

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

        return capped(result + pending, keeping: visible)
    }

    /// Drops closed entries from the front, which is the oldest arrangement, until the list is
    /// within budget. Truncating the list itself would take the newest workspaces instead: `merged`
    /// appends the ones it has just seen at the end.
    internal static func capped(_ ids: [WorkspaceID], keeping visible: Set<WorkspaceID>) -> [WorkspaceID] {
        guard ids.count > maxStoredEntries else { return ids }
        var surplus = ids.count - maxStoredEntries
        var kept: [WorkspaceID] = []
        kept.reserveCapacity(maxStoredEntries)

        for id in ids {
            if surplus > 0, !visible.contains(id) {
                surplus -= 1
                continue
            }
            kept.append(id)
        }
        return kept
    }
}
