//
//  QueryEditorView.swift
//  TablePro
//

import SwiftUI
import TableProEditorKit
import TableProPluginKit

/// The SQL editor, its command bar, and the banners that belong to the document it holds.
struct QueryEditorView: View {
    @Binding var queryText: String
    @Binding var cursorPositions: [CursorPosition]
    @Binding var parameters: [QueryParameter]
    @Binding var isParameterPanelVisible: Bool
    var schemaProvider: SQLSchemaProvider?
    var databaseType: DatabaseType?
    var databaseScope: DatabaseScope?
    var connectionId: UUID?
    var connectionAIPolicy: AIConnectionPolicy?
    var tabID: UUID?
    var claimFocusOnAppear: Bool = false
    var onFocusClaimed: (() -> Void)?
    var restoredCursorRange: NSRange?
    var pendingStatementJump: StatementAnchor?
    var onStatementJumpHandled: (() -> Void)?
    var restoredFoldRanges: [Range<Int>]?
    var onFoldRangesChanged: (([Range<Int>]) -> Void)?
    var onCloseTab: (() -> Void)?
    var onExecuteQuery: (() -> Void)?
    var onRunStatement: ((String, Int) -> Bool)?
    var isExecuting: Bool = false
    var onAIExplain: ((String) -> Void)?
    var onAIOptimize: ((String) -> Void)?
    var onSaveAsFavorite: ((String) -> Void)?

    let scope: QueryScopeBarModel
    let commands: QueryCommandAvailability
    var onRun: () -> Void
    var onRunAllStatements: () -> Void
    var onRunWithoutLimit: () -> Void
    var onStop: () -> Void
    var onExplain: (ExplainVariant?) -> Void
    var onFormat: () -> Void
    var onSaveAsFavoriteCommand: () -> Void
    var onClearQuery: () -> Void
    var onClearResults: () -> Void
    var onContainerChanged: (String) -> Void

    @State private var vimMode: VimMode = .normal

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            QueryEditorBar(
                scope: scope,
                commands: commands,
                isExecuting: isExecuting,
                vimMode: AppSettingsManager.shared.editor.vimModeEnabled ? vimMode : nil,
                onRun: onRun,
                onRunAllStatements: onRunAllStatements,
                onRunWithoutLimit: onRunWithoutLimit,
                onStop: onStop,
                onExplain: onExplain,
                onFormat: onFormat,
                onSaveAsFavorite: onSaveAsFavoriteCommand,
                onClearQuery: onClearQuery,
                onClearResults: onClearResults,
                onContainerChanged: onContainerChanged
            )

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
                databaseScope: databaseScope,
                connectionId: connectionId,
                connectionAIPolicy: connectionAIPolicy,
                tabID: tabID,
                claimFocusOnAppear: claimFocusOnAppear,
                onFocusClaimed: onFocusClaimed,
                restoredCursorRange: restoredCursorRange,
                pendingStatementJump: pendingStatementJump,
                onStatementJumpHandled: onStatementJumpHandled,
                restoredFoldRanges: restoredFoldRanges,
                onFoldRangesChanged: onFoldRangesChanged,
                vimMode: $vimMode,
                onCloseTab: onCloseTab,
                onExecuteQuery: onExecuteQuery,
                onRunStatement: onRunStatement,
                isExecuting: isExecuting,
                onAIExplain: onAIExplain,
                onAIOptimize: onAIOptimize,
                onSaveAsFavorite: onSaveAsFavorite
            )
            .frame(minHeight: 100)
            .clipped()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
