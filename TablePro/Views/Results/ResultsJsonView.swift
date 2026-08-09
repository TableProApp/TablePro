//
//  ResultsJsonView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

internal struct ResultsJsonView: View {
    let tableRows: TableRows
    let selectedRowIndices: Set<Int>
    let displayIDs: [RowID]?
    let dataRevision: Int
    let displayRevision: Int
    let columnLayout: ColumnLayoutState

    @State private var viewMode: JSONViewMode
    @State private var treeSearchText = ""
    @State private var parsedTree: JSONTreeNode?
    @State private var parseError: JSONTreeParseError?
    @State private var prettyText = ""
    @State private var cachedJson = ""
    @State private var resolvedRowCount: Int
    @State private var hasRendered = false
    @State private var copied = false
    @State private var copyCooldownTask: Task<Void, Never>?

    init(
        tableRows: TableRows,
        selectedRowIndices: Set<Int>,
        displayIDs: [RowID]?,
        dataRevision: Int,
        displayRevision: Int,
        columnLayout: ColumnLayoutState
    ) {
        self.tableRows = tableRows
        self.selectedRowIndices = selectedRowIndices
        self.displayIDs = displayIDs
        self.dataRevision = dataRevision
        self.displayRevision = displayRevision
        self.columnLayout = columnLayout
        self._viewMode = State(initialValue: AppSettingsManager.shared.editor.jsonViewerPreferredMode)
        self._resolvedRowCount = State(
            initialValue: selectedRowIndices.isEmpty ? tableRows.count : selectedRowIndices.count
        )
    }

    private struct RenderKey: Equatable {
        let dataRevision: Int
        let displayRevision: Int
        let selectedRowIndices: Set<Int>
        let hiddenColumns: Set<String>
        let columnOrder: [String]?
    }

    private var renderKey: RenderKey {
        RenderKey(
            dataRevision: dataRevision,
            displayRevision: displayRevision,
            selectedRowIndices: selectedRowIndices,
            hiddenColumns: columnLayout.hiddenColumns,
            columnOrder: columnLayout.columnOrder
        )
    }

    private var rowCountText: String {
        let rowCount = tableRows.count
        if selectedRowIndices.isEmpty || resolvedRowCount == rowCount {
            return String(format: String(localized: "%d rows"), rowCount)
        }
        return String(format: String(localized: "%d of %d rows"), resolvedRowCount, rowCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: renderKey) {
            await rebuild()
        }
        .onChange(of: viewMode) {
            AppSettingsManager.shared.editor.jsonViewerPreferredMode = viewMode
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(rowCountText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Picker("", selection: $viewMode) {
                Text("Text").tag(JSONViewMode.text)
                Text("Tree").tag(JSONViewMode.tree)
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Spacer()

            Button {
                ClipboardService.shared.writeText(cachedJson)
                copied = true
                copyCooldownTask?.cancel()
                copyCooldownTask = Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(1_500))
                        copied = false
                    } catch {
                        // cancelled by next press
                    }
                }
            } label: {
                Label(
                    copied ? String(localized: "Copied!") : String(localized: "Copy JSON"),
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!hasRendered)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if tableRows.rows.isEmpty {
            ContentUnavailableView(
                String(localized: "No Data"),
                systemImage: "curlybraces",
                description: Text(String(localized: "Execute a query to view results as JSON"))
            )
        } else if !hasRendered {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch viewMode {
            case .text:
                JSONCodeEditor(text: $prettyText, isEditable: false)
            case .tree:
                if let tree = parsedTree {
                    JSONTreeView(rootNode: tree, searchText: $treeSearchText)
                } else if let error = parseError {
                    treeErrorView(error)
                } else {
                    treeErrorView(.invalidJSON)
                }
            }
        }
    }

    private func treeErrorView(_ error: JSONTreeParseError) -> some View {
        ContentUnavailableView {
            Label(
                error == .tooLarge
                    ? String(localized: "JSON Too Large")
                    : String(localized: "Invalid JSON"),
                systemImage: error == .tooLarge ? "doc.text" : "exclamationmark.triangle"
            )
        } description: {
            Text(
                error == .tooLarge
                    ? String(localized: "This JSON document is too large for tree view. Use text mode instead.")
                    : String(localized: "The text could not be parsed as JSON.")
            )
        }
    }

    // MARK: - JSON Generation

    private func rebuild() async {
        let snapshot = tableRows
        let ids = displayIDs
        let selectedIndices = selectedRowIndices
        let layout = columnLayout

        let result = await Task.detached(priority: .userInitiated) {
            Self.computeJson(
                tableRows: snapshot,
                displayIDs: ids,
                selectedIndices: selectedIndices,
                columnLayout: layout
            )
        }.value

        guard !Task.isCancelled else { return }
        cachedJson = result.json
        prettyText = result.pretty
        resolvedRowCount = result.resolvedCount
        switch result.parseResult {
        case .success(let node):
            parsedTree = node
            parseError = nil
        case .failure(let error):
            parsedTree = nil
            parseError = error
        }
        hasRendered = true
    }

    /// Renders the rows the grid is showing, through the same serializer as Copy as JSON.
    nonisolated static func computeJson(
        tableRows: TableRows,
        displayIDs: [RowID]?,
        selectedIndices: Set<Int>,
        columnLayout: ColumnLayoutState
    ) -> (json: String, pretty: String, resolvedCount: Int, parseResult: Result<JSONTreeNode, JSONTreeParseError>) {
        let output = ResultJsonSerializer.serialize(
            tableRows: tableRows,
            displayIDs: displayIDs,
            selectedDisplayIndices: selectedIndices,
            columns: .fromColumnLayout(columnLayout, columns: tableRows.columns)
        )
        let pretty = output.json.prettyPrintedAsJson() ?? output.json
        return (
            json: output.json,
            pretty: pretty,
            resolvedCount: output.rowCount,
            parseResult: JSONTreeParser.parse(output.json)
        )
    }
}
