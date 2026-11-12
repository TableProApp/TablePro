//
//  QueryCommandAvailability.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// What the query tab's command bar can do right now.
///
/// Pure, the way `ResultStatusModel` and `QueryResultPresentation` are, so the whole enable matrix
/// is decidable without mounting a view. The bar used to answer this inline: `disabled(!hasQuery)`
/// written out at four call sites, each with its own idea of what "has a query" meant, and Format
/// with no gate at all.
struct QueryCommandAvailability {
    let canRun: Bool
    let canStop: Bool
    let canExplain: Bool
    let canFormat: Bool
    let canSaveAsFavorite: Bool
    let canClearQuery: Bool
    let canClearResults: Bool
    /// Save is Cmd+S for this tab, so it is live when Cmd+S would do something here: write the tab's
    /// changed file or the grid edits it holds, or ask where to keep a query that has no file yet.
    let canSave: Bool
    /// Query Builder is the Join Builder sheet, which only an engine with a SQL dialect and foreign
    /// keys can fill, so elsewhere the button is left out rather than shown dimmed for good.
    let showsQueryBuilder: Bool
    let canOpenQueryBuilder: Bool
    /// Whether the Run menu has anything live in it. Clear Query leaves the results standing and
    /// takes `canRun` away with it, so gating the menu on Run alone hid Clear Results at the one
    /// moment it was the command the reader wanted.
    let canOpenRunMenu: Bool
    let explainVariants: [ExplainVariant]
    let aiActions: AIQueryActionAvailability

    /// Every hint the bar shows, resolved here so a disabled control can say why rather than just
    /// dimming. A control that dims without explaining is the one thing a reader cannot act on.
    let runHint: String
    let stopHint: String
    let explainHint: String
    let formatHint: String
    let favoriteHint: String
    let aiReviewHint: String
    let saveHint: String
    let beautifyHint: String
    let queryBuilderHint: String

    /// `isStoppable` is separate from `isExecuting` because a batch whose `COMMIT` is on the wire is
    /// still running and can no longer be stopped by anything: the HIG asks not to offer a cancel
    /// that cannot act.
    init(
        isConnected: Bool,
        hasQueryText: Bool,
        isExecuting: Bool,
        isStoppable: Bool,
        hasResults: Bool,
        explainVariants: [ExplainVariant],
        supportsFormatting: Bool = true,
        aiActions: AIQueryActionAvailability = .hidden,
        hasUnsavedEdits: Bool = false,
        hasSourceFile: Bool = false,
        supportsQueryBuilder: Bool = false,
        shortcutHint: (String, ShortcutAction) -> String
    ) {
        self.explainVariants = explainVariants
        self.aiActions = aiActions
        aiReviewHint = aiActions.hint(base: shortcutHint(AIQueryAction.review.menuTitle, .aiReviewQuery))
        canRun = isConnected && hasQueryText && !isExecuting
        canStop = isExecuting && isStoppable
        canExplain = Self.canExplain(
            isConnected: isConnected,
            hasQueryText: hasQueryText,
            isExecuting: isExecuting,
            supportsExplain: !explainVariants.isEmpty
        )
        /// Formatting rewrites text the reader already has, so it does not wait for a server.
        canFormat = hasQueryText && supportsFormatting
        canSaveAsFavorite = hasQueryText
        canClearQuery = hasQueryText
        canClearResults = hasResults
        canOpenRunMenu = canRun || hasQueryText || hasResults
        canSave = hasUnsavedEdits || (!hasSourceFile && hasQueryText)
        showsQueryBuilder = supportsQueryBuilder
        /// The sheet reads the database's tables and foreign keys, so it waits for the session.
        canOpenQueryBuilder = supportsQueryBuilder && isConnected

        runHint = Self.hint(
            base: shortcutHint(String(localized: "Run"), .executeQuery),
            reason: Self.blockedReason(isConnected: isConnected, hasQueryText: hasQueryText, isExecuting: isExecuting)
        )
        stopHint = Self.hint(
            base: shortcutHint(String(localized: "Stop"), .cancelQuery),
            reason: isExecuting && !isStoppable
                ? String(localized: "The batch is committing and cannot be stopped.")
                : nil
        )
        explainHint = Self.hint(
            base: shortcutHint(String(localized: "Explain"), .explainQuery),
            reason: explainVariants.isEmpty
                ? String(localized: "This database does not explain statements.")
                : Self.blockedReason(isConnected: isConnected, hasQueryText: hasQueryText, isExecuting: isExecuting)
        )
        formatHint = Self.hint(
            base: shortcutHint(String(localized: "Format"), .formatQuery),
            reason: !supportsFormatting
                ? String(localized: "This query language has no formatter.")
                : hasQueryText ? nil : String(localized: "There is nothing to format yet.")
        )
        favoriteHint = Self.hint(
            base: shortcutHint(String(localized: "Save as Favorite"), .saveAsFavorite),
            reason: hasQueryText ? nil : String(localized: "There is nothing to save yet.")
        )
        saveHint = Self.hint(
            base: shortcutHint(String(localized: "Save"), .saveChanges),
            reason: canSave ? nil : String(localized: "There is nothing to save yet.")
        )
        beautifyHint = Self.hint(
            base: shortcutHint(String(localized: "Beautify SQL"), .formatQuery),
            reason: !supportsFormatting
                ? String(localized: "This query language has no formatter.")
                : hasQueryText ? nil : String(localized: "There is nothing to format yet.")
        )
        queryBuilderHint = Self.hint(
            base: String(localized: "Build Join Query"),
            reason: canOpenQueryBuilder ? nil : String(localized: "This connection is not available.")
        )
    }

    /// The one rule for Explain, shared by the editor bar and the Query menu so the button and the
    /// menu item's shortcut cannot disagree. An engine explains only through a variant it declares.
    static func canExplain(isConnected: Bool, hasQueryText: Bool, isExecuting: Bool, supportsExplain: Bool) -> Bool {
        isConnected && hasQueryText && !isExecuting && supportsExplain
    }

    private static func blockedReason(isConnected: Bool, hasQueryText: Bool, isExecuting: Bool) -> String? {
        if isExecuting { return String(localized: "A query is already running.") }
        if !hasQueryText { return String(localized: "There is nothing to run yet.") }
        if !isConnected { return String(localized: "This connection is not available.") }
        return nil
    }

    private static func hint(base: String, reason: String?) -> String {
        guard let reason else { return base }
        return "\(base)\n\(reason)"
    }
}

/// What the editor bar's leading control names: the container this tab's SQL runs in.
struct QueryScopeBarModel {
    let containers: [DatabaseMetadata]
    let selectedName: String
    let entityName: String
    let isReadOnly: Bool
    let schemaName: String?
}
