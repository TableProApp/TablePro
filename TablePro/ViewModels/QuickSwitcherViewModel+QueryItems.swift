//
//  QuickSwitcherViewModel+QueryItems.swift
//  TablePro
//

import Foundation

internal extension QuickSwitcherViewModel {
    nonisolated static func makeHistoryItems(_ entries: [QueryHistoryEntry]) -> [QuickSwitcherItem] {
        distinctByQuery(entries).prefix(QuickSwitcherRanking.localHistoryLimit).map { entry in
            QuickSwitcherItem(
                frecencyKey: QuickSwitcherFrecencyKey.queryHistory(entry.query),
                name: entry.queryPreview,
                kind: .queryHistory,
                subtitle: entry.databaseDisplayName,
                payload: entry.query
            )
        }
    }

    nonisolated static func makeCrossConnectionQueryItems(
        favorites: [SQLFavorite],
        historyEntries: [QueryHistoryEntry],
        targets: [UUID: QuickSwitcherTarget],
        currentConnectionId: UUID
    ) -> [QuickSwitcherItem] {
        let favoriteItems = favorites.compactMap { favorite -> QuickSwitcherItem? in
            let targetConnectionId = favorite.connectionId ?? currentConnectionId
            guard let target = targets[targetConnectionId] else { return nil }
            let subtitle = [favorite.keyword, connectionPath(for: target)]
                .compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
                .joined(separator: " · ")
            return QuickSwitcherItem(
                frecencyKey: QuickSwitcherFrecencyKey.savedQuery(favorite.id),
                name: favorite.name,
                kind: .savedQuery,
                subtitle: subtitle,
                keyword: favorite.keyword,
                payload: favorite.query,
                target: target
            )
        }

        let historyItems = distinctByQuery(historyEntries).compactMap { entry -> QuickSwitcherItem? in
            guard let baseTarget = targets[entry.connectionId] else { return nil }
            let databaseName = entry.databaseName.isEmpty ? nil : entry.databaseName
            let target = QuickSwitcherTarget(
                connectionId: baseTarget.connectionId,
                connectionName: baseTarget.connectionName,
                databaseName: databaseName,
                schemaName: nil,
                databaseDisplayName: databaseDisplayName(
                    databaseName,
                    pathFieldRole: baseTarget.pathFieldRole
                )
            )
            return QuickSwitcherItem(
                frecencyKey: QuickSwitcherFrecencyKey.queryHistory(entry.query),
                name: entry.queryPreview,
                kind: .queryHistory,
                subtitle: [
                    connectionPath(for: target),
                    entry.hasMeasuredDuration ? entry.formattedExecutionTime : ""
                ]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                payload: entry.query,
                target: target
            )
        }

        return interleaveToCap(favoriteItems, historyItems, cap: QuickSwitcherRanking.maxResults)
    }

    /// The switcher is a recall list, so one statement run twenty times is one thing to recall.
    /// Every execution stays in history; only the list collapses them, keeping the most recent.
    nonisolated static func distinctByQuery(_ entries: [QueryHistoryEntry]) -> [QueryHistoryEntry] {
        var seen: Set<HistoryStatement> = []
        var distinct: [QueryHistoryEntry] = []
        for entry in entries {
            let query = QuickSwitcherFrecencyKey.normalizedQuery(entry.query)
            guard !query.isEmpty,
                  seen.insert(HistoryStatement(connectionId: entry.connectionId, query: query)).inserted else {
                continue
            }
            distinct.append(entry)
        }
        return distinct
    }

    /// Concatenating and truncating let a long favourites list push recent queries out of the
    /// panel entirely. Each source keeps its own half of the cap and only lends what it does
    /// not use.
    nonisolated static func interleaveToCap(
        _ favorites: [QuickSwitcherItem],
        _ history: [QuickSwitcherItem],
        cap: Int
    ) -> [QuickSwitcherItem] {
        guard favorites.count + history.count > cap else { return favorites + history }

        let share = cap / 2
        let favoriteCount = min(favorites.count, max(share, cap - history.count))
        let historyCount = min(history.count, cap - favoriteCount)
        return Array(favorites.prefix(favoriteCount)) + Array(history.prefix(historyCount))
    }

    nonisolated static func interleaveByConnection(
        _ perConnection: [[QueryHistoryEntry]],
        limit: Int
    ) -> [QueryHistoryEntry] {
        var queues = perConnection.filter { !$0.isEmpty }
        var merged: [QueryHistoryEntry] = []
        var queueIndex = 0
        while merged.count < limit, !queues.isEmpty {
            if queueIndex >= queues.count { queueIndex = 0 }
            merged.append(queues[queueIndex].removeFirst())
            if queues[queueIndex].isEmpty {
                queues.remove(at: queueIndex)
            } else {
                queueIndex += 1
            }
        }
        return merged.sorted { $0.executedAt > $1.executedAt }
    }
}

private struct HistoryStatement: Hashable {
    let connectionId: UUID
    let query: String
}
