//
//  VersionHistoryTabView.swift
//  TablePro
//

import Combine
import SwiftUI

internal struct VersionHistoryTabView: View {
    let tabId: UUID
    let databaseType: DatabaseType
    let exportFileName: String
    let onOpenInEditor: (String) -> Void

    @StateObject private var viewModel: VersionHistoryViewModel

    init(
        tabId: UUID,
        subject: VersionHistorySubject,
        databaseType: DatabaseType,
        exportFileName: String,
        onOpenInEditor: @escaping (String) -> Void
    ) {
        self.tabId = tabId
        self.databaseType = databaseType
        self.exportFileName = exportFileName
        self.onOpenInEditor = onOpenInEditor
        _viewModel = StateObject(wrappedValue: VersionHistoryFactory.makeViewModel(for: subject))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .task { await viewModel.loadList() }
            .onReceive(AppEvents.shared.versionHistoryRefreshRequested) { requestedTabId in
                guard requestedTabId == tabId else { return }
                viewModel.reload()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.listState {
        case .failed(let message):
            UnavailableStateView {
                Label(String(localized: "History Unavailable"), systemImage: "clock.arrow.circlepath")
            } description: {
                Text(message)
            } actions: {
                Button(String(localized: "Try Again")) { viewModel.reload() }
            }
        case .loading where viewModel.page.entries.isEmpty:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            AutosavingSplitView(
                autosaveName: "com.TablePro.versionHistory.listDetail",
                primaryMinimum: 220,
                secondaryMinimum: 360,
                primaryThicknessFraction: 0.3,
                primaryAutomaticMaximum: 360
            ) {
                VersionHistoryListPane(viewModel: viewModel)
            } secondary: {
                VersionHistoryDetailPane(
                    viewModel: viewModel,
                    databaseType: databaseType,
                    exportFileName: exportFileName,
                    onOpenInEditor: onOpenInEditor
                )
            }
        }
    }
}
