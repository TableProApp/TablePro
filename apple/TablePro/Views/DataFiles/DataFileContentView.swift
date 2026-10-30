//
//  DataFileContentView.swift
//  TablePro
//

import SwiftUI
import TableProTabular
import TableProTheme

struct DataFileContentView: View {
    @ObservedObject var controller: DataFileController

    var body: some View {
        VStack(spacing: 0) {
            if controller.filterState.isVisible, controller.loadState == .loaded {
                DataFileFilterPanel(controller: controller)
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
        .themeBackground(.windowBackdrop, native: Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch controller.loadState {
        case .idle, .loading:
            loadingView
                .gridStandInBackground()
        case .failed(let message):
            UnavailableStateView(String(localized: "This file can’t be opened"), systemImage: "exclamationmark.triangle", description: Text(message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gridStandInBackground()
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
        DataGridView(model: controller.gridModel)
            .onAppear { controller.gridModel.configuration = configuration }
            .onChange(of: configuration) { controller.gridModel.configuration = $0 }
    }

    private var emptyView: some View {
        let hasRows = controller.totalRowCount > 0
        return UnavailableStateView(
            hasRows ? String(localized: "No matching rows") : String(localized: "No rows"),
            systemImage: hasRows ? "line.3.horizontal.decrease.circle" : "doc"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themeBackground(.gridBackground, native: Color(nsColor: .textBackgroundColor))
    }

    private var configuration: DataGridConfiguration {
        Self.gridConfiguration(for: controller)
    }

    static func gridConfiguration(for controller: DataFileController) -> DataGridConfiguration {
        var config = DataGridConfiguration()
        let isEditable = controller.isEditable && !controller.isBusy
        config.showRowNumbers = true
        config.isEditable = isEditable
        config.supportsValueFilter = false
        config.appliesRowCopyFormat = true
        var commands: Set<DataGridCommand> = [
            .filterWithColumn, .hideColumns, .showRowsAsJSON, .exportResults, .freezeColumns, .displayAs,
        ]
        if isEditable {
            commands.formUnion([.addRow, .deleteRows, .pasteRows])
        }
        config.commands = commands
        return config
    }
}

struct DataFileSheetTabs: View {
    /// The HIG's limit for tabs, past which it asks for a pop-up menu instead.
    static let segmentedSheetLimit = 6

    @ObservedObject var controller: DataFileController

    var body: some View {
        HStack {
            if controller.sheets.count <= Self.segmentedSheetLimit {
                picker.viewSwitcherStyle()
            } else {
                picker.pickerStyle(.menu)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .disabled(controller.isBusy)
    }

    private var picker: some View {
        Picker(String(localized: "Sheet"), selection: Binding(
            get: { controller.selectedSheetIndex },
            set: { controller.selectSheet($0) }
        )) {
            ForEach(Array(controller.sheets.enumerated()), id: \.offset) { index, sheet in
                Text(sheet.isHidden ? String(format: String(localized: "%@ (hidden)"), sheet.name) : sheet.name)
                    .tag(index)
            }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(String(localized: "Sheet"))
        .accessibilityIdentifier("data-file-sheet-picker")
    }
}
