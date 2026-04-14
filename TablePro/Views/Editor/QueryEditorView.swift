//
//  QueryEditorView.swift
//  TablePro
//
//  SQL query editor wrapper with toolbar
//

import CodeEditSourceEditor
import os
import SwiftUI
import TableProPluginKit

/// SQL query editor view with execute button
struct QueryEditorView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryEditorView")


    @Binding var queryText: String
    @Binding var cursorPositions: [CursorPosition]
    var onExecute: () -> Void
    var schemaProvider: SQLSchemaProvider?
    var databaseType: DatabaseType?
    var connectionId: UUID?
    var connectionAIPolicy: AIConnectionPolicy?
    var onCloseTab: (() -> Void)?
    var onExecuteQuery: (() -> Void)?
    var onExplain: ((ClickHouseExplainVariant?) -> Void)?
    var onExplainVariant: ((ExplainVariant) -> Void)?
    var onAIExplain: ((String) -> Void)?
    var onAIOptimize: ((String) -> Void)?
    var onSaveAsFavorite: ((String) -> Void)?

    @State private var vimMode: VimMode = .normal

    var body: some View {
        let hasQuery = !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(alignment: .leading, spacing: 0) {
            // Editor header with toolbar (above editor, higher z-index)
            editorToolbar(hasQueryText: hasQuery)
                .zIndex(1)

            Divider()

            // SQL Editor (CodeEditSourceEditor-based with tree-sitter highlighting)
            SQLEditorView(
                text: $queryText,
                cursorPositions: $cursorPositions,
                schemaProvider: schemaProvider,
                databaseType: databaseType,
                connectionId: connectionId,
                connectionAIPolicy: connectionAIPolicy,
                vimMode: $vimMode,
                onCloseTab: onCloseTab,
                onExecuteQuery: onExecuteQuery,
                onAIExplain: onAIExplain,
                onAIOptimize: onAIOptimize,
                onSaveAsFavorite: onSaveAsFavorite,
                onFormatSQL: formatQuery
            )
            .frame(minHeight: 100)
            .clipped()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Toolbar

    private func editorToolbar(hasQueryText: Bool) -> some View {
        HStack {
            Text("Query")
                .font(.headline)
                .foregroundStyle(.secondary)

            if AppSettingsManager.shared.editor.vimModeEnabled {
                VimModeIndicatorView(mode: vimMode)
            }

            Spacer()

            // Clear button
            Button(action: { queryText = "" }) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Clear Query"))

            // Format button
            Button(action: formatQuery) {
                Image(systemName: "text.alignleft")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Format Query (⇧⌘L)"))
            .optionalKeyboardShortcut(AppSettingsManager.shared.keyboard.keyboardShortcut(for: .formatQuery))

            Divider()
                .frame(height: 16)

            explainButton(hasQueryText: hasQueryText)

            // Execute button
            Button(action: onExecute) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text("Execute")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func explainButton(hasQueryText: Bool) -> some View {
        let variants = databaseType.flatMap {
            PluginMetadataRegistry.shared.snapshot(forTypeId: $0.pluginTypeId)?.explainVariants
        } ?? []

        if variants.count <= 1 {
            Button {
                if let variant = variants.first {
                    if let handler = onExplainVariant {
                        handler(variant)
                    } else {
                        onExplain?(nil)
                    }
                } else {
                    onExplain?(nil)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.doc.horizontal")
                    Text("Explain")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!hasQueryText)
        } else {
            Menu {
                ForEach(variants) { variant in
                    Button(variant.label) {
                        if let handler = onExplainVariant {
                            handler(variant)
                        } else if let legacy = ClickHouseExplainVariant(rawValue: variant.label) {
                            onExplain?(legacy)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.doc.horizontal")
                    Text("Explain")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!hasQueryText)
        }
    }

    private func formatQuery() {
        // Get current database type
        let dbType = databaseType ?? .mysql

        // Create formatter service
        let formatter = SQLFormatterService()
        let options = SQLFormatterOptions.default

        let cursorOffset = cursorPositions.first?.range.location ?? 0

        do {
            // Format SQL with cursor preservation
            let result = try formatter.format(
                queryText,
                dialect: dbType,
                cursorOffset: cursorOffset,
                options: options
            )

            // Update text and cursor position
            queryText = result.formattedSQL
            if let newCursor = result.cursorOffset {
                cursorPositions = [CursorPosition(range: NSRange(location: newCursor, length: 0))]
            }
        } catch {
            Self.logger.error("SQL Formatting error: \(error.localizedDescription, privacy: .public)")
        }
    }
}

#Preview {
    QueryEditorView(
        queryText: .constant("SELECT * FROM users\nWHERE active = true\nORDER BY created_at DESC;"),
        cursorPositions: .constant([]),
        onExecute: {},
        databaseType: .mysql
    )
    .frame(width: 600, height: 200)
}
