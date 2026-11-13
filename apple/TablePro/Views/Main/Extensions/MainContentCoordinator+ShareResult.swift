//
//  MainContentCoordinator+ShareResult.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    // Shares the active result as a public link: the selected rows, or the whole loaded result when
    // nothing is selected, capped and sent to the share service, then the URL is put on the clipboard.
    func shareActiveResult() {
        guard let tab = tabManager.selectedTab else { return }
        let tableRows = tabSessionRegistry.tableRows(for: tab.id)
        guard !tableRows.rows.isEmpty else { return }

        let model = gridModel(forTab: tab.id)
        let selectedDisplayIndices = Set(model.selectedRowIDs.compactMap { model.displayIndex(of: $0) })
        let hasSelection = !selectedDisplayIndices.isEmpty
        let projection = VisibleColumnProjection(indices: model.columns.columns.map(\.dataIndex))
        let read = DisplayedResultReader.read(
            tableRows: tableRows,
            displayIDs: model.order.filteredIDs,
            selectedDisplayIndices: selectedDisplayIndices,
            defaultedCells: model.changeState?.defaultedCells(in: tableRows) ?? [:],
            columns: projection
        )
        guard !read.rows.isEmpty else { return }

        let sql = (tab.pagination.baseQueryForMore ?? tab.content.query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { return }

        let built = ResultSnapshotBuilder.build(
            from: read,
            totalRowCount: hasSelection ? nil : (tab.pagination.hasExactRowCount ? tab.pagination.totalRowCount : nil),
            moreRowsAvailable: hasSelection ? false : tab.pagination.hasMoreRows
        )

        let window = contentWindow
        Task { @MainActor in
            let client = ShareClient(api: AccountServices.shared.api)
            do throws(ShareFailure) {
                let link = try await client.createResult(
                    title: tab.title,
                    sql: sql,
                    note: nil,
                    dialect: connection.type.rawValue,
                    snapshot: built.snapshot
                )
                ClipboardService.shared.writeText(link.url)
                AlertHelper.showInfoSheet(
                    title: String(localized: "Share Result"),
                    message: String(localized: "A public link to this result is on your clipboard."),
                    window: window
                )
            } catch {
                guard let message = error.createMessage else { return }
                AlertHelper.showInfoSheet(title: String(localized: "Share Result"), message: message, window: window)
            }
        }
    }
}
