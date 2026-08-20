//
//  TextViewController+StatementRunning.swift
//  CodeEditSourceEditor
//

import AppKit

/// The editor's side of running one statement at a time.
///
/// The host finds the statements, because only the host knows the language. This publishes them in the gutter, calls
/// back with the one whose control was pressed, and paints the band behind whichever one the host says is active.
public extension TextViewController {
    /// The statements the gutter offers to run, in document order.
    ///
    /// Set this whenever the document changes. The editor holds the array and reads it while drawing, so a host that
    /// keeps its own cache pays nothing per frame.
    var runnableStatements: [StatementRun] {
        get { gutterView?.statementRunRibbon.statements ?? [] }
        set { gutterView?.statementRunRibbon.statements = newValue }
    }

    /// Called with the statement whose gutter control was pressed, by pointer or by assistive technology.
    var onRunStatement: ((StatementRun) -> Void)? {
        get { gutterView?.statementRunRibbon.onRun }
        set { gutterView?.statementRunRibbon.onRun = newValue }
    }

    /// Whether pressing a run control does anything right now.
    ///
    /// A host that allows one execution at a time turns this off while a query runs. The controls stay drawn and dim
    /// rather than vanishing, so the gutter does not flicker for the length of a query.
    var statementRunControlsEnabled: Bool {
        get { gutterView?.statementRunRibbon.isEnabled ?? false }
        set { gutterView?.statementRunRibbon.isEnabled = newValue }
    }

    /// What assistive technology reads for the run control column.
    var statementRunAccessibilityLabel: String {
        get { gutterView?.statementRunRibbon.accessibilityGroupLabel ?? "" }
        set { gutterView?.statementRunRibbon.accessibilityGroupLabel = newValue }
    }

    /// The format assistive technology reads for one control, given the 1-based line its statement starts on.
    var statementRunAccessibilityLabelFormat: String {
        get { gutterView?.statementRunRibbon.accessibilityLabelFormat ?? "" }
        set { gutterView?.statementRunRibbon.accessibilityLabelFormat = newValue }
    }

    /// The span painted as a band behind the text, or `nil` to paint none.
    ///
    /// A decoration rather than a selection, so it survives the reader's next keystroke instead of being replaced by
    /// it.
    var highlightedStatementRange: NSRange? {
        get { (textView as? SourceEditorTextView)?.statementHighlightRange }
        set { (textView as? SourceEditorTextView)?.statementHighlightRange = newValue }
    }
}
