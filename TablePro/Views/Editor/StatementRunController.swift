//
//  StatementRunController.swift
//  TablePro
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import TableProPluginKit

/// Which way a statement navigation command moves the caret.
enum StatementNavigationDirection {
    case previous
    case next
}

/// Keeps the editor's per-statement decorations in step with the document.
///
/// Two things are drawn from one scanner: the run control the gutter puts beside each statement, and the band behind
/// the statement the caret is in. Both come from ``SQLStatementScanner``, which is also what decides the SQL that
/// actually runs, so a control cannot offer to run something different from what it is drawn beside.
///
/// The two are refreshed differently because they cost differently. The band resolves one statement through
/// ``SQLStatementScanner/locatedStatementAtCursor(in:cursorPosition:dialect:)``, which stops at the caret, so it is
/// the same call the execution path makes and it can run on every keystroke. The controls need every statement in the
/// document, which is a full pass: measured at 31ms on a document at the size limit, well past a frame, so that one is
/// debounced. Nothing is lost by the delay, since the controls only show while the pointer is over the gutter.
@MainActor
final class StatementRunController {
    /// The largest document decorations are computed for, in UTF-16 units.
    ///
    /// The same threshold syntax highlighting and code folding stop at, so an editor that has given up on colouring a
    /// document does not still be walking it for statement boundaries.
    static let defaultSizeLimit = 2_000_000

    /// How long typing has to pause before the run controls are recomputed.
    static let refreshDelay: Duration = .milliseconds(150)

    /// Below this length the controls are recomputed on the keystroke rather than on the pause.
    ///
    /// A full pass is 6ms at 190KB and 31ms at the size limit, so debouncing is only worth its staleness on a large
    /// document. Measured; see `StatementRunPerformanceGuardTests`.
    static let synchronousRefreshLimit = 64_000

    var sizeLimit = StatementRunController.defaultSizeLimit
    var dialect: SqlDialect = .generic

    /// Called with the SQL the pressed control stands for, read from the document at the moment of the press.
    ///
    /// Text rather than a range, because the caller substrings a different string: the SwiftUI binding the tab holds
    /// lags the text view, and a range resolved against the wrong one silently truncates. A `DELETE ... WHERE ...`
    /// cut short is still a statement the driver will accept.
    var onRun: ((String) -> Bool)?

    /// Whether the band is drawn at all.
    ///
    /// Held here rather than only in the theme, which resolves the band to a transparent colour when the setting is
    /// off, because a band nobody can see is not worth resolving the caret's statement for on every keystroke.
    var isHighlightEnabled = true

    private var pendingRefresh: Task<Void, Never>?
    /// Latched because the owning view writes it from `body`, which runs before the editor has a controller to
    /// receive it. Without this an editor created while its tab is already running draws its controls undimmed.
    private var isEnabled = true

    func install(on controller: TextViewController) {
        controller.statementRunAccessibilityLabel = String(localized: "Run statement")
        controller.statementRunAccessibilityLabelFormat = String(
            localized: "Run the statement starting on line %d"
        )
        controller.onRunStatement = { [weak self] statement in
            self?.run(statement, in: controller)
        }
        controller.statementBoundaryProvider = { [weak self, weak controller] offset, forward in
            self?.statementBoundary(from: offset, forward: forward, in: controller)
        }
        controller.statementRunControlsEnabled = isEnabled
        refreshControls(in: controller)
        refreshHighlight(in: controller)
    }

    /// Whether pressing a run control does anything right now.
    ///
    /// The controls stay drawn while a query runs and go dim, rather than disappearing and coming back, so the gutter
    /// does not flicker for the length of the query.
    ///
    /// Guarded on the current value because the owning view writes this from `body`, which SwiftUI runs far more often
    /// than the execution state changes, and every write marks the gutter for redisplay.
    func setEnabled(_ isEnabled: Bool, in controller: TextViewController?) {
        self.isEnabled = isEnabled
        guard let controller, controller.statementRunControlsEnabled != isEnabled else { return }
        controller.statementRunControlsEnabled = isEnabled
    }

    /// Queues a recompute of the run controls. Call after the document changes.
    ///
    /// Small documents skip the queue entirely, so the ranges the gutter draws from stay in step with the text on
    /// every keystroke rather than for everything but the last 150ms of typing.
    func scheduleControlsRefresh(in controller: TextViewController?) {
        pendingRefresh?.cancel()
        guard let controller else { return }

        if (controller.textView?.string as NSString?)?.length ?? 0 <= Self.synchronousRefreshLimit {
            refreshControls(in: controller)
            return
        }

        pendingRefresh = Task { [weak self, weak controller] in
            try? await Task.sleep(for: Self.refreshDelay)
            guard !Task.isCancelled, let self, let controller else { return }
            self.refreshControls(in: controller)
        }
    }

    /// Recomputes the run controls now, without waiting out the debounce.
    func refreshControls(in controller: TextViewController?) {
        guard let controller, let textView = controller.textView else { return }
        let text = textView.string

        guard (text as NSString).length <= sizeLimit else {
            controller.runnableStatements = []
            return
        }

        controller.runnableStatements = SQLStatementScanner
            .navigableStatements(in: text, dialect: dialect)
            .map { StatementRun(range: $0.contentRange) }
    }

    /// Moves the caret to the start of the statement before or after the one it is in.
    ///
    /// Rescans rather than reading the drawn controls, which a large document lets fall up to one debounce behind the
    /// text. Anchors on the first caret and leaves a single one behind, matching how the band picks its statement.
    func moveCursor(_ direction: StatementNavigationDirection, in controller: TextViewController?) {
        guard let controller, let textView = controller.textView else { return }
        let text = textView.string
        guard (text as NSString).length <= sizeLimit else { return }
        guard let caret = controller.cursorPositions.first?.range.location else { return }

        guard let destination = statementStart(direction, from: caret, in: text) else { return }
        controller.moveCursor(to: destination)
    }

    /// The offset `Option+Shift+Up` and `Option+Shift+Down` extend the selection to.
    ///
    /// Forward reaches the far edge of the last statement rather than the start of the next one, or the last
    /// statement's own body could never be selected.
    func statementBoundary(from offset: Int, forward: Bool, in controller: TextViewController?) -> Int? {
        guard let controller, let textView = controller.textView else { return nil }
        let text = textView.string
        guard (text as NSString).length <= sizeLimit else { return nil }
        guard forward else {
            return SQLStatementScanner.statementStart(before: offset, in: text, dialect: dialect)
        }
        return SQLStatementScanner.statementSelectionEnd(after: offset, in: text, dialect: dialect)
    }

    /// The SQL of the statement the caret is in, or `nil` when there is nothing to run there.
    ///
    /// Capped the same way navigation is, so run-and-advance cannot run without also being able to advance.
    func statementAtCursor(in controller: TextViewController?) -> String? {
        guard let controller, let textView = controller.textView else { return nil }
        let text = textView.string
        guard (text as NSString).length <= sizeLimit else { return nil }
        guard let selection = controller.cursorPositions.first, selection.range.length == 0 else { return nil }

        let statement = SQLStatementScanner.locatedStatementAtCursor(
            in: text,
            cursorPosition: selection.range.location,
            dialect: dialect
        )
        guard statement.hasContent, statement.contentRange.length > 0 else { return nil }
        return (text as NSString).substring(with: statement.contentRange)
    }

    private func statementStart(_ direction: StatementNavigationDirection, from offset: Int, in text: String) -> Int? {
        switch direction {
        case .previous:
            return SQLStatementScanner.statementStart(before: offset, in: text, dialect: dialect)
        case .next:
            return SQLStatementScanner.statementStart(after: offset, in: text, dialect: dialect)
        }
    }

    /// Moves the band to the statement the caret is in. Call after the selection changes.
    func refreshHighlight(in controller: TextViewController?) {
        guard let controller else { return }
        controller.highlightedStatementRange = highlightRange(in: controller)
    }

    func clear(in controller: TextViewController?) {
        pendingRefresh?.cancel()
        pendingRefresh = nil
        controller?.runnableStatements = []
        controller?.highlightedStatementRange = nil
        controller?.onRunStatement = nil
        controller?.statementBoundaryProvider = nil
    }

    // MARK: - Private

    /// Resolves what a pressed control stands for against the document as it is right now.
    ///
    /// The control was drawn from a range the last scan produced, and on a large document that scan can be up to one
    /// debounce old. Rather than trust the range, this re-reads the statement that currently starts there and refuses
    /// the press if the document has moved under it, which is fail-closed: the worst outcome is a click that does
    /// nothing and a gutter that redraws.
    private func run(_ statement: StatementRun, in controller: TextViewController) {
        guard let textView = controller.textView else { return }
        let text = textView.string
        let length = (text as NSString).length
        guard statement.range.location < length else {
            refreshControls(in: controller)
            return
        }

        let resolved = SQLStatementScanner.locatedStatementAtCursor(
            in: text,
            cursorPosition: statement.range.location,
            dialect: dialect
        )
        guard resolved.hasContent, resolved.contentRange == statement.range else {
            refreshControls(in: controller)
            return
        }

        _ = onRun?((text as NSString).substring(with: resolved.contentRange))
    }

    /// The span the band covers, or `nil` when there is nothing to mark.
    ///
    /// A non-empty selection runs verbatim rather than being widened to its statement, so the band steps aside and
    /// lets the selection speak for itself. Multiple carets resolve through the first one, which is the caret the
    /// execution path reads too.
    private func highlightRange(in controller: TextViewController) -> NSRange? {
        guard isHighlightEnabled,
              let textView = controller.textView,
              let selection = controller.cursorPositions.first,
              selection.range.length == 0 else {
            return nil
        }

        let text = textView.string
        guard (text as NSString).length <= sizeLimit else { return nil }

        let statement = SQLStatementScanner.locatedStatementAtCursor(
            in: text,
            cursorPosition: selection.range.location,
            dialect: dialect
        )
        guard statement.hasContent, statement.contentRange.length > 0 else { return nil }
        return statement.contentRange
    }
}
