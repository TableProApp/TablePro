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
    /// Whether the Run menu has anything live in it. Clear Query leaves the results standing and
    /// takes `canRun` away with it, so gating the menu on Run alone hid Clear Results at the one
    /// moment it was the command the reader wanted.
    let canOpenRunMenu: Bool
    let explainVariants: [ExplainVariant]

    /// Every hint the bar shows, resolved here so a disabled control can say why rather than just
    /// dimming. A control that dims without explaining is the one thing a reader cannot act on.
    let runHint: String
    let stopHint: String
    let explainHint: String
    let formatHint: String
    let favoriteHint: String

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
        shortcutHint: (String, ShortcutAction) -> String
    ) {
        self.explainVariants = explainVariants
        canRun = isConnected && hasQueryText && !isExecuting
        canStop = isExecuting && isStoppable
        canExplain = Self.canExplain(
            isConnected: isConnected,
            hasQueryText: hasQueryText,
            isExecuting: isExecuting,
            supportsExplain: !explainVariants.isEmpty
        )
        /// Formatting rewrites text the reader already has, so it does not wait for a server.
        canFormat = hasQueryText
        canSaveAsFavorite = hasQueryText
        canClearQuery = hasQueryText
        canClearResults = hasResults
        canOpenRunMenu = canRun || hasQueryText || hasResults

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
            reason: hasQueryText ? nil : String(localized: "There is nothing to format yet.")
        )
        favoriteHint = Self.hint(
            base: shortcutHint(String(localized: "Save as Favorite"), .saveAsFavorite),
            reason: hasQueryText ? nil : String(localized: "There is nothing to save yet.")
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
