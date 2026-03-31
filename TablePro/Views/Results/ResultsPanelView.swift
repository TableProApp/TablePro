//
//  ResultsPanelView.swift
//  TablePro
//
//  Main container that orchestrates result tab bar, error banners, and result content.
//  Will replace resultsSection() in MainEditorContentView in Phase 3.
//

import SwiftUI

struct ResultsPanelView: View {
    let tab: QueryTab
    let connection: DatabaseConnection
    var coordinator: MainContentCoordinator?

    // Callbacks matching DataGridView expectations
    var onCellEdit: ((Int, Int, String?) -> Void)?
    var onDeleteRows: ((Set<Int>) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if tab.resultSets.count > 1 {
                ResultTabBar(
                    resultSets: tab.resultSets,
                    activeResultSetId: activeResultSetBinding,
                    onClose: closeResultSet,
                    onPin: togglePin
                )
                Divider()
            }

            if let error = tab.activeResultSet?.errorMessage {
                InlineErrorBanner(
                    message: error,
                    onDismiss: { tab.activeResultSet?.errorMessage = nil },
                    onAIFix: nil
                )
                Divider()
            }

            resultContent

            // Note: MainStatusBarView integration happens in Phase 3
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if let rs = tab.activeResultSet {
            if !rs.resultColumns.isEmpty {
                // Has data: DataGridView integration happens in Phase 3
                Text(String(format: String(localized: "DataGridView placeholder for: %@"), rs.label))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rs.errorMessage == nil {
                ResultSuccessView(
                    rowsAffected: rs.rowsAffected,
                    executionTime: rs.executionTime,
                    statusMessage: rs.statusMessage
                )
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Run a query to see results")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var activeResultSetBinding: Binding<UUID?> {
        Binding(
            get: { tab.activeResultSetId },
            set: { newId in
                if let coord = coordinator,
                   let tabIdx = coord.tabManager.selectedTabIndex {
                    coord.tabManager.tabs[tabIdx].activeResultSetId = newId
                }
            }
        )
    }

    private func closeResultSet(_ id: UUID) {
        guard let coord = coordinator,
              let tabIdx = coord.tabManager.selectedTabIndex else { return }
        let rs = coord.tabManager.tabs[tabIdx].resultSets.first { $0.id == id }
        guard rs?.isPinned != true else { return }
        coord.tabManager.tabs[tabIdx].resultSets.removeAll { $0.id == id }
        if tab.activeResultSetId == id {
            coord.tabManager.tabs[tabIdx].activeResultSetId =
                coord.tabManager.tabs[tabIdx].resultSets.last?.id
        }
        if coord.tabManager.tabs[tabIdx].resultSets.isEmpty {
            coord.tabManager.tabs[tabIdx].rowBuffer = RowBuffer()
            coord.tabManager.tabs[tabIdx].resultColumns = []
            coord.tabManager.tabs[tabIdx].columnTypes = []
            coord.tabManager.tabs[tabIdx].resultRows = []
            coord.tabManager.tabs[tabIdx].errorMessage = nil
            coord.tabManager.tabs[tabIdx].rowsAffected = 0
            coord.tabManager.tabs[tabIdx].executionTime = nil
            coord.tabManager.tabs[tabIdx].statusMessage = nil
            coord.tabManager.tabs[tabIdx].resultVersion += 1
        }
    }

    private func togglePin(_ id: UUID) {
        guard let rs = tab.resultSets.first(where: { $0.id == id }) else { return }
        rs.isPinned.toggle()
    }
}

#Preview("No results") {
    let tab = QueryTab(title: "Query 1")
    ResultsPanelView(
        tab: tab,
        connection: DatabaseConnection.preview
    )
    .frame(width: 600, height: 400)
}
