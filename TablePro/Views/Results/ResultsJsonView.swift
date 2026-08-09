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
        dataRevision: Int
    ) {
        self.tableRows = tableRows
        self.selectedRowIndices = selectedRowIndices
        self.displayIDs = displayIDs
        self.dataRevision = dataRevision
        self._viewMode = State(initialValue: AppSettingsManager.shared.editor.jsonViewerPreferredMode)
        self._resolvedRowCount = State(
            initialValue: selectedRowIndices.isEmpty ? tableRows.count : selectedRowIndices.count
        )
    }

    private struct RenderKey: Equatable {
        let dataRevision: Int
        let selectedRowIndices: Set<Int>
    }

    private var renderKey: RenderKey {
        RenderKey(dataRevision: dataRevision, selectedRowIndices: selectedRowIndices)
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

        let result = await Task.detached(priority: .userInitiated) {
            Self.computeJson(tableRows: snapshot, displayIDs: ids, selectedIndices: selectedIndices)
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

    /// Selection indices are display positions, so they are resolved through
    /// ``DisplayRowMapping`` rather than used to subscript `tableRows.rows` directly: a
    /// per-column value filter or a sort makes the two diverge.
    nonisolated static func computeJson(
        tableRows: TableRows,
        displayIDs: [RowID]?,
        selectedIndices: Set<Int>
    ) -> (json: String, pretty: String, resolvedCount: Int, parseResult: Result<JSONTreeNode, JSONTreeParseError>) {
        let displayRows: [[PluginCellValue]]
        if selectedIndices.isEmpty {
            displayRows = tableRows.rows.map { Array($0.values) }
        } else {
            displayRows = selectedIndices.sorted().compactMap { displayIndex in
                DisplayRowMapping.row(forDisplay: displayIndex, displayIDs: displayIDs, in: tableRows)
                    .map { Array($0.values) }
            }
        }
        let converter = JsonRowConverter(columns: tableRows.columns, columnTypes: tableRows.columnTypes)
        let json = converter.generateJson(rows: displayRows)
        let pretty = json.prettyPrintedAsJson() ?? json
        return (
            json: json,
            pretty: pretty,
            resolvedCount: displayRows.count,
            parseResult: JSONTreeParser.parse(json)
        )
    }
}
