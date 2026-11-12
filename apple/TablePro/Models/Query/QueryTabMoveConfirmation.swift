//
//  QueryTabMoveConfirmation.swift
//  TablePro
//

import AppKit

/// How a query bar pick puts its question: a sheet on the tab's window in the app, and an answer without one under
/// test, where an app-modal alert would hold the run.
internal typealias QueryTabMoveConfirming = @MainActor (QueryTabMoveConfirmation, NSWindow?) async -> Bool

/// The question the two-row query bar asks before a pick moves a tab to another connection.
///
/// The menu sits in the editor, a click away from the text, so a slip would send the tab's next run somewhere the
/// reader did not mean. A target the reader marked as needing care, by a production tag or a Safe Mode level, says so,
/// and there Return cancels rather than moves.
internal struct QueryTabMoveConfirmation: Equatable {
    internal let title: String
    internal let message: String
    internal let cancelIsDefault: Bool

    @MainActor
    internal init(tabTitle: String, sourceName: String, target: DatabaseConnection, targetTags: [ConnectionTag]) {
        title = String(format: String(localized: "Move “%@” to “%@”?"), tabTitle, target.name)
        var sentences = [
            String(format: String(localized: "The tab leaves “%@”, and its next run goes to “%@”."), sourceName, target.name),
        ]
        let production = targetTags.first { Self.isProductionTag($0) }
        if let production {
            sentences.append(String(format: String(localized: "“%@” is tagged %@."), target.name, production.name))
        }
        let level = target.safeModeLevel
        if level != .silent {
            sentences.append(
                String(format: String(localized: "“%@” has its Safe Mode level set to %@."), target.name, level.displayName)
            )
        }
        message = sentences.joined(separator: " ")
        cancelIsDefault = production != nil || level != .silent
    }

    /// The preset's name, which every Mac maps to one record, compared the way tag names are matched.
    internal static func isProductionTag(_ tag: ConnectionTag) -> Bool {
        tag.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("production") == .orderedSame
    }

    /// Built apart from its presentation, so a test reads the buttons with no window. Over a marked target Cancel comes
    /// first and keeps Return, as quitting with unsaved edits does, and Move takes a deliberate click.
    @MainActor
    internal func makeAlert() -> (alert: NSAlert, moveResponse: NSApplication.ModalResponse) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let move = String(localized: "Move")
        let cancel = String(localized: "Cancel")
        guard cancelIsDefault else {
            alert.alertStyle = .informational
            alert.addButton(withTitle: move)
            AlertHelper.addCancelButton(to: alert, title: cancel)
            return (alert, .alertFirstButtonReturn)
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: cancel).keyEquivalent = "\r"
        alert.addButton(withTitle: move).keyEquivalent = ""
        return (alert, .alertSecondButtonReturn)
    }

    @MainActor
    internal static func present(_ confirmation: QueryTabMoveConfirmation, in window: NSWindow?) async -> Bool {
        let (alert, moveResponse) = confirmation.makeAlert()
        return await AlertHelper.response(to: alert, in: window) == moveResponse
    }
}
