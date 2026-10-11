//
//  DataFileRowDetailsView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

struct DataFileRowDetailsView: View {
    static let databaseType = DatabaseType(rawValue: "DataFile")
    static let typingCommitDelay: Duration = .milliseconds(400)

    @ObservedObject var controller: DataFileController
    @StateObject private var editState = MultiRowEditState()
    @State private var pendingCommit: Task<Void, Never>?
    @State private var pendingEdit: DataFilePendingEdit?
    @State private var configuredKey: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if selectedPageRow == nil {
                UnavailableStateView(
                    String(localized: "No Row Selected"),
                    systemImage: "sidebar.trailing",
                    description: Text(String(localized: "Select a row to see its fields."))
                )
            } else {
                InspectorFieldListView(
                    editState: editState,
                    isEditable: controller.isEditable && !controller.isBusy,
                    databaseType: Self.databaseType,
                    userDefinedTypeScope: nil,
                    offersDatabaseValues: false
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: configure)
        .onChange(of: controller.selectedRowIndices) { _ in configure() }
        .onChange(of: controller.pageRevision) { _ in configure() }
        .onDisappear(perform: flushPendingCommit)
    }

    private var header: some View {
        Text(headerText)
            .font(.headline)
            .lineLimit(1)
            .padding(.horizontal, InspectorMetrics.horizontalInset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("data-file-row-details-header")
    }

    private var headerText: String {
        guard let row = selectedPageRow else { return String(localized: "Row Details") }
        return String(
            format: String(localized: "Row %@ of %@"),
            (controller.pageOffset + row + 1).formatted(),
            controller.visibleRowCount.formatted()
        )
    }

    private var selectedPageRow: Int? {
        guard controller.selectedRowIndices.count == 1, let row = controller.selectedRowIndices.first,
              controller.tableRows.rows.indices.contains(row) else { return nil }
        return row
    }

    private func configure() {
        flushPendingCommit()
        guard let row = selectedPageRow else {
            configuredKey = nil
            return
        }
        let values = controller.tableRows.rows[row].values.map { value -> String? in
            guard case .text(let text) = value else { return nil }
            return text
        }
        configuredKey = controller.key(forPageRow: row)
        editState.configure(
            selectedRowIndices: [row],
            allRows: [values],
            columns: controller.tableRows.columns,
            columnTypes: controller.tableRows.columnTypes
        )
        editState.onFieldChanged = { column, value, continuity in
            scheduleCommit(column: column, value: value, continuity: continuity)
        }
    }

    private func scheduleCommit(column: Int, value: PluginCellValue, continuity: FieldEditContinuity) {
        guard let key = configuredKey else { return }
        let text: String
        switch value {
        case .text(let content): text = content
        case .null, .bytes: text = ""
        }
        pendingCommit?.cancel()
        pendingEdit = DataFilePendingEdit(key: key, column: column, text: text)
        guard continuity == .typing else {
            flushPendingCommit()
            return
        }
        pendingCommit = Task { @MainActor in
            try? await Task.sleep(for: Self.typingCommitDelay)
            guard !Task.isCancelled else { return }
            flushPendingCommit()
        }
    }

    private func flushPendingCommit() {
        pendingCommit?.cancel()
        pendingCommit = nil
        guard let edit = pendingEdit else { return }
        pendingEdit = nil
        guard let pageRow = controller.pageKeys.firstIndex(of: edit.key) else { return }
        controller.setCell(pageRow: pageRow, column: edit.column, text: edit.text)
    }
}

private struct DataFilePendingEdit: Equatable {
    let key: Int
    let column: Int
    let text: String
}
