//
//  DataFileContentView.swift
//  TablePro
//

import SwiftUI
import TableProTabular

struct DataFileContentView: View {
    @ObservedObject var controller: DataFileController
    let gridDelegate: DataFileGridDelegate

    var body: some View {
        VStack(spacing: 0) {
            if controller.filterState.isVisible, controller.loadState == .loaded {
                DataFileFilterPanel(controller: controller)
                Divider()
            }
            if controller.find.isVisible, controller.loadState == .loaded {
                DataFileFindBar(controller: controller)
                Divider()
            }
            content
            if controller.sheets.count > 1 {
                Divider()
                DataFileSheetTabs(controller: controller)
            }
            Divider()
            DataFileStatusBar(controller: controller)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch controller.loadState {
        case .idle, .loading:
            loadingView
        case .failed(let message):
            UnavailableStateView(String(localized: "This file can’t be opened"), systemImage: "exclamationmark.triangle", description: Text(message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            ZStack {
                grid
                if controller.tableRows.rows.isEmpty, !controller.isQueryRunning {
                    emptyView
                }
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView(value: controller.loadProgress)
                .progressViewStyle(.linear)
                .frame(width: 220)
            Text(String(format: String(localized: "Opening… %@"), controller.loadProgress.formatted(.percent.precision(.fractionLength(0)))))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var grid: some View {
        DataGridView(
            tableRowsProvider: { controller.tableRows },
            tableRowsMutator: { _ in },
            paginationOffsetProvider: { controller.pageOffset },
            changeManager: controller.anyChangeManager,
            isEditable: controller.isEditable && !controller.isBusy,
            configuration: configuration,
            delegate: gridDelegate,
            selectedRowIndices: $controller.selectedRowIndices,
            sortState: Binding(
                get: { controller.sortState },
                set: { controller.updateSort($0) }
            ),
            columnLayout: $controller.columnLayout
        )
        .accessibilityIdentifier("data-grid")
    }

    private var emptyView: some View {
        let hasRows = controller.totalRowCount > 0
        return UnavailableStateView(
            hasRows ? String(localized: "No matching rows") : String(localized: "No rows"),
            systemImage: hasRows ? "line.3.horizontal.decrease.circle" : "doc"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var configuration: DataGridConfiguration {
        var config = DataGridConfiguration()
        config.showRowNumbers = true
        config.hiddenColumns = controller.columnLayout.hiddenColumns
        return config
    }
}

struct DataFileSheetTabs: View {
    @ObservedObject var controller: DataFileController

    var body: some View {
        HStack {
            Picker(String(localized: "Sheet"), selection: Binding(
                get: { controller.selectedSheetIndex },
                set: { controller.selectSheet($0) }
            )) {
                ForEach(Array(controller.sheets.enumerated()), id: \.offset) { index, sheet in
                    Text(sheet.isHidden ? String(format: String(localized: "%@ (hidden)"), sheet.name) : sheet.name)
                        .tag(index)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(String(localized: "Sheet"))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
