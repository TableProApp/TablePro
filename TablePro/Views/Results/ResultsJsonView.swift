//
//  ResultsJsonView.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

internal struct ResultsJsonView: View {
    let tableRows: TableRows
    let selectedRowIndices: Set<Int>

    @State private var viewMode: JSONViewMode
    @State private var treeSearchText = ""
    @State private var parsedTree: JSONTreeNode?
    @State private var parseError: JSONTreeParseError?
    @State private var prettyText = ""
    @State private var cachedJson = ""
    @State private var copied = false
    @State private var renderToken: Int = 0
    @State private var copyCooldownTask: Task<Void, Never>?

    init(
        tableRows: TableRows,
        selectedRowIndices: Set<Int>
    ) {
        self.tableRows = tableRows
        self.selectedRowIndices = selectedRowIndices
        self._viewMode = State(initialValue: AppSettingsManager.shared.editor.jsonViewerPreferredMode)
    }

    private var rowCountText: String {
        let rowCount = tableRows.count
        let selectedCount = selectedRowIndices.count
        let displaying = selectedCount == 0 ? rowCount : selectedCount
        if selectedRowIndices.isEmpty || displaying == rowCount {
            return String(format: String(localized: "%d rows"), rowCount)
        }
        return String(format: String(localized: "%d of %d rows"), displaying, rowCount)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { startRebuild() }
        .onChange(of: selectedRowIndices) { startRebuild() }
        .onChange(of: tableRows.count) { startRebuild() }
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
        } else {
            switch viewMode {
            case .text:
                JSONSyntaxTextView(
                    text: $prettyText,
                    isEditable: false,
                    wordWrap: true
                )
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

    private func startRebuild() {
        renderToken &+= 1
        let token = renderToken
        let columns = tableRows.columns
        let columnTypes = tableRows.columnTypes
        let rowsSnapshot = tableRows.rows
        let selectedIndices = selectedRowIndices

        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) {
                Self.computeJson(
                    columns: columns,
                    columnTypes: columnTypes,
                    rows: rowsSnapshot,
                    selectedIndices: selectedIndices
                )
            }.value

            guard token == renderToken else { return }
            cachedJson = result.json
            prettyText = result.pretty
            switch result.parseResult {
            case .success(let node):
                parsedTree = node
                parseError = nil
            case .failure(let error):
                parsedTree = nil
                parseError = error
            }
        }
    }

    nonisolated private static func computeJson(
        columns: [String],
        columnTypes: [ColumnType],
        rows: ContiguousArray<Row>,
        selectedIndices: Set<Int>
    ) -> (json: String, pretty: String, parseResult: Result<JSONTreeNode, JSONTreeParseError>) {
        let allRows: [[PluginCellValue]] = rows.map { Array($0.values) }
        let displayRows: [[PluginCellValue]]
        if selectedIndices.isEmpty {
            displayRows = allRows
        } else {
            displayRows = selectedIndices.sorted().compactMap {
                allRows.indices.contains($0) ? allRows[$0] : nil
            }
        }
        let converter = JsonRowConverter(columns: columns, columnTypes: columnTypes)
        let json = converter.generateJson(rows: displayRows)
        let pretty = json.prettyPrintedAsJson() ?? json
        let parseResult = JSONTreeParser.parse(json)
        return (json: json, pretty: pretty, parseResult: parseResult)
    }
}
