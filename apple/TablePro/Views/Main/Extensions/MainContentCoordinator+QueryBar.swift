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
    /// connection pick is Move Tab to Connection.
    func queryBarTwoRowInput(forTab tabId: UUID) -> QueryEditorBar.TwoRowInput {
        QueryEditorBar.TwoRowInput(
            connection: QueryConnectionPickerModel(
                connectionId: connection.id,
                name: connection.name,
                color: connection.color,
                canMove: canMoveTabToConnection(tabId),
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
}
