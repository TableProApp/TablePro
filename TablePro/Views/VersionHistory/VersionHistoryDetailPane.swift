//
//  VersionHistoryDetailPane.swift
//  TablePro
//

import SwiftUI

internal struct VersionHistoryDetailPane: View {
    @ObservedObject var viewModel: VersionHistoryViewModel
    let databaseType: DatabaseType
    let exportFileName: String
    let onOpenInEditor: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VersionHistoryDetailHeader(viewModel: viewModel)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch viewModel.detailState {
        case .empty:
            UnavailableStateView(String(localized: "No Version Selected"), systemImage: "clock.arrow.circlepath")
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            UnavailableStateView {
                Label(String(localized: "Version Unavailable"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .loaded(let loaded):
            switch viewModel.displayMode {
            case .changes:
                VersionHistoryChangesView(
                    detail: loaded,
                    layout: viewModel.diffLayout,
                    databaseType: databaseType,
                    exportFileName: exportFileName,
                    onOpenInEditor: onOpenInEditor
                )
            case .content:
                VersionHistoryContentView(
                    content: loaded.content,
                    databaseType: databaseType,
                    exportFileName: exportFileName,
                    onOpenInEditor: onOpenInEditor
                )
            }
        }
    }
}
