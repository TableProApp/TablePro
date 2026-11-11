//
//  MainContentCoordinator+QueryBar.swift
//  TablePro
//

import Foundation

@MainActor
extension MainContentCoordinator {
    /// What the two-row query bar adds for one query tab. Built only while the setting is on, so the
    /// single-row bar reads neither the connection library nor the saved queries.
    ///
    /// Each command is the one the rest of the app already runs: Save is Cmd+S, Query Builder is the
    /// Join Builder sheet, a saved query goes in the way completion inserts a favorite, and a
    /// connection pick is Move Tab to Connection once the reader confirms it.
    func queryBarTwoRowInput(forTab tabId: UUID) -> QueryEditorBar.TwoRowInput {
        QueryEditorBar.TwoRowInput(
            connection: QueryConnectionPickerModel(
                connectionId: connection.id,
                name: connection.name,
                color: connection.color,
                canMove: canMoveTabToConnection(tabId),
                confirm: { [weak self] target in
                    guard let self else { return false }
                    return await self.confirmQueryTabMove(tabId, to: target)
                },
                move: { [weak self] target in self?.moveQueryTab(tabId, toConnection: target) }
            ),
            savedQueries: ConnectionDataCache.shared(for: connectionId),
            onSave: { [weak self] in self?.commandActions?.saveChanges() },
            onOpenQueryBuilder: { [weak self] in self?.openJoinBuilder(forQueryTab: tabId) },
            onInsertSavedQuery: { favorite in
                EditorEventRouter.shared.insertSavedQueryForKeyWindow(favorite.query)
            }
        )
    }

    /// The question a pick in the query bar asks before the tab moves. The target is read from the
    /// library when picked, so the question names the tag and Safe Mode level it has now. The menu lists
    /// only saved connections, so a target missing here was deleted since, and it is refused unasked.
    func confirmQueryTabMove(_ tabId: UUID, to targetId: UUID) async -> Bool {
        guard let tab = tabManager.tabs.first(where: { $0.id == tabId }),
              let target = services.connectionStorage.loadConnections().first(where: { $0.id == targetId })
        else { return false }
        let confirmation = QueryTabMoveConfirmation(
            tabTitle: tab.title,
            sourceName: connection.name,
            target: target,
            targetTags: services.tagStorage.tags(for: target.tagIds)
        )
        return await askToMoveQueryTab(confirmation, contentWindow)
    }
}
