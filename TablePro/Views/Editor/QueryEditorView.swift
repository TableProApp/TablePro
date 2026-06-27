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
    @Binding var queryText: String
    @Binding var cursorPositions: [CursorPosition]
    @Binding var parameters: [QueryParameter]
    @Binding var isParameterPanelVisible: Bool
    var onExecute: () -> Void
    var schemaProvider: SQLSchemaProvider?
    var databaseType: DatabaseType?
    var connectionId: UUID?
    var connectionAIPolicy: AIConnectionPolicy?
    var tabID: UUID?
    var claimFocusOnAppear: Bool = false
    var onCloseTab: (() -> Void)?
    var onExecuteQuery: (() -> Void)?
    var onExplain: ((ClickHouseExplainVariant?) -> Void)?
    var onExplainVariant: ((ExplainVariant) -> Void)?
    var onAIExplain: ((String) -> Void)?
    var onAIOptimize: ((String) -> Void)?
    var onSaveAsFavorite: ((String) -> Void)?
    var onClearResults: (() -> Void)?
    var availableContainers: [DatabaseMetadata] = []
    var selectedContainerName: String = ""
    var containerEntityName: String = ""
    var isContainerSwitchReadOnly: Bool = false
    var onContainerChanged: ((String) -> Void)?

    @State private var vimMode: VimMode = .normal

    var body: some View {
        let hasQuery = !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(alignment: .leading, spacing: 0) {
            // Editor header with toolbar (above editor, higher z-index)
            editorToolbar(hasQueryText: hasQuery)
                .zIndex(1)

            Divider()

            if isParameterPanelVisible && !parameters.isEmpty {
                QueryParameterPanelView(
                    parameters: $parameters,
                    onDismiss: { isParameterPanelVisible = false }
                )
                Divider()
            }

            SQLEditorView(
                text: $queryText,
                cursorPositions: $cursorPositions,
                schemaProvider: schemaProvider,
                databaseType: databaseType,
                connectionId: connectionId,
                connectionAIPolicy: connectionAIPolicy,
                tabID: tabID,
                claimFocusOnAppear: claimFocusOnAppear,
                vimMode: $vimMode,
                onCloseTab: onCloseTab,
                onExecuteQuery: onExecuteQuery,
                onAIExplain: onAIExplain,
                onAIOptimize: onAIOptimize,
                onSaveAsFavorite: onSaveAsFavorite
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

            QueryContainerPicker(
                containers: availableContainers,
                selectedName: selectedContainerName,
                entityName: containerEntityName,
                isReadOnly: isContainerSwitchReadOnly,
                onChange: { name in onContainerChanged?(name) }
            )

            Spacer()

            Button(action: {
                queryText = ""
                onClearResults?()
            }) {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Clear Query"))
            .accessibilityLabel(String(localized: "Clear Query"))

            Button(action: formatQuery) {
                Image(systemName: "text.alignleft")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(shortcutHint(String(localized: "Format Query"), for: .formatQuery))
            .accessibilityLabel(String(localized: "Format Query"))
            .optionalKeyboardShortcut(AppSettingsManager.shared.keyboard.keyboardShortcut(for: .formatQuery))

            Button(action: { onSaveAsFavorite?(queryText) }) {
                Image(systemName: "star")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(shortcutHint(String(localized: "Save as Favorite"), for: .saveAsFavorite))
            .accessibilityLabel(String(localized: "Save as Favorite"))
            .disabled(!hasQueryText)

            Divider()
                .frame(height: 16)

            explainButton(hasQueryText: hasQueryText)

            Button(action: onExecute) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text("Execute")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(shortcutHint(String(localized: "Execute"), for: .executeQuery))
            .optionalKeyboardShortcut(AppSettingsManager.shared.keyboard.keyboardShortcut(for: .executeQuery))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers

    private func shortcutHint(_ label: String, for action: ShortcutAction) -> String {
        AppSettingsManager.shared.keyboard.shortcutHint(label, for: action)
    }

    @ViewBuilder
    private func explainButton(hasQueryText: Bool) -> some View {
        let variants = databaseType?.explainVariants ?? []

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
            .help(shortcutHint(String(localized: "Explain"), for: .explainQuery))
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
            .help(shortcutHint(String(localized: "Explain"), for: .explainQuery))
            .disabled(!hasQueryText)
        }
    }

    private func formatQuery() {
        EditorEventRouter.shared.performFormatSQLForKeyWindow()
    }
}

#Preview {
    QueryEditorView(
        queryText: .constant("SELECT * FROM users\nWHERE active = true\nORDER BY created_at DESC;"),
        cursorPositions: .constant([]),
        parameters: .constant([]),
        isParameterPanelVisible: .constant(false),
        onExecute: {},
        databaseType: .mysql
    )
    .frame(width: 600, height: 200)
}
