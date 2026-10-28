//
//  TableStructureView+TableOptions.swift
//  TablePro
//

import SwiftUI

internal extension TableStructureView {
    var tableOptionsView: some View {
        TableOptionsView(
            session: session,
            changeManager: structureChangeManager,
            isReadOnly: toolbarState.safeModeLevel.blocksAllWrites || isSessionBound,
            autoIncrementMaximum: autoIncrementMaximum,
            onRetry: { Task { await session.readTableOptions() } },
            onRetryCatalog: { Task { await session.readTableOptionsCatalog() } }
        )
        .task { await session.readTableOptionsCatalog() }
    }

    // The draft's column, not the loaded one: the counter is set after the column work in the same save.
    private var autoIncrementMaximum: UInt64? {
        let columns = structureChangeManager.workingColumns
        let index = columns.indices.first { index in
            columns[index].autoIncrement
                && !structureChangeManager.deleteInsertState(for: index, tab: .columns).isDeleted
        }
        return index.map { AutoIncrementEntry.maximum(for: columns[$0]) }
    }

    func loadTableOptionsCatalogIfNeeded() async {
        guard session.needsTableOptionsCatalog else { return }
        await session.readTableOptionsCatalog()
    }

    // Like the comment: options changed elsewhere refetch columns identical to the loaded ones.
    func onTableOptionsChanged() {
        rebaselineUnlessEdited()
    }

    // A retried read can return the options already loaded, which moves only this.
    func onAutoIncrementReadChanged(_ read: AutoIncrementReadState) {
        guard read == .confirmed else { return }
        rebaselineUnlessEdited()
    }
}
