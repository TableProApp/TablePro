import Foundation
import Observation
import TableProModels
import TableProQuery
import TableProSQLGrammar
import UIKit

@MainActor
@Observable
final class SQLEditorHandle {
    private(set) var hasSelection = false
    private(set) var runNote: String?

    @ObservationIgnored var databaseType: DatabaseType? {
        didSet { if databaseType != oldValue { refreshBand() } }
    }

    @ObservationIgnored var sessionFacts: SQLSessionLexicalFacts? {
        didSet { if sessionFacts != oldValue { refreshBand() } }
    }

    @ObservationIgnored private(set) weak var textView: UITextView?
    @ObservationIgnored private var publishText: ((String) -> Void)?
    @ObservationIgnored private var band: StatementBand?
    @ObservationIgnored private var nothingToRunState: EditorState?
    @ObservationIgnored private var pendingSelection: EditorState?
    @ObservationIgnored private var isPublishScheduled = false

    private struct EditorState: Equatable {
        let text: String
        let selection: NSRange
    }

    func attach(_ textView: UITextView, publishText: @escaping (String) -> Void = { _ in }) {
        self.textView = textView
        self.publishText = publishText
        band = StatementBand(textView: textView)
        editorDidChange()
    }

    // Through the text view, so Undo brings back what was there; assigning the binding would empty the undo stack.
    // Off the window the undo step has nowhere to live, so the caller waits until the editor shows.
    var isInWindow: Bool {
        textView?.window != nil
    }

    @discardableResult
    func add(_ query: String) -> Bool {
        guard let databaseType, let textView, textView.window != nil else { return false }
        let edit = QueryTextInsertion.edit(
            adding: query, to: textView.text ?? "", databaseType: databaseType, session: sessionFacts
        )
        guard let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
              let end = textView.position(from: start, offset: edit.range.length),
              let range = textView.textRange(from: start, to: end) else { return false }
        textView.replace(range, withText: edit.text)
        textView.selectedRange = edit.selection
        textView.scrollRangeToVisible(edit.selection)
        publishText?(textView.text ?? "")
        editorDidChange()
        return true
    }

    // Text set through the binding reaches the text view on its next update, so its selection waits for that text.
    func select(_ selection: NSRange, onceTextIs text: String) {
        pendingSelection = EditorState(text: text, selection: selection)
        applyPendingSelection()
    }

    private func applyPendingSelection() {
        guard let pending = pendingSelection, let textView, (textView.text ?? "") == pending.text else { return }
        pendingSelection = nil
        textView.selectedRange = pending.selection
        textView.scrollRangeToVisible(pending.selection)
    }

    func runTarget() -> QueryRunTarget {
        guard let databaseType, let textView else { return .nothing }
        return QueryRunTarget.resolve(
            in: textView.text ?? "",
            selection: textView.selectedRange,
            databaseType: databaseType,
            session: sessionFacts
        )
    }

    // Not through the focus binding: its resign runs inside updateUIView, and a Run tap then hung in a view graph cycle.
    func endEditing() {
        textView?.resignFirstResponder()
    }

    func noteNothingToRun() {
        nothingToRunState = currentState()
        schedulePublish()
        AccessibilityNotification.Announcement(Self.nothingToRunMessage).post()
    }

    func clearRunNote() {
        nothingToRunState = nil
        schedulePublish()
    }

    func editorDidChange() {
        applyPendingSelection()
        refreshBand()
        // Tapping Run resigns the editor after the note is posted, which is no reason to drop it.
        if let nothingToRunState, nothingToRunState != currentState() {
            self.nothingToRunState = nil
        }
        schedulePublish()
    }

    private static var nothingToRunMessage: String {
        String(localized: "The cursor is not in a statement.")
    }

    private func currentState() -> EditorState {
        EditorState(text: textView?.text ?? "", selection: textView?.selectedRange ?? NSRange(location: 0, length: 0))
    }

    private func refreshBand() {
        guard let band else { return }
        band.show(bandRange())
    }

    private func bandRange() -> NSRange? {
        // The band stops where colouring stops.
        guard let textView, textView.textStorage.length <= SQLSyntaxHighlighter.maxHighlightLength,
              case .statement(_, let range) = runTarget() else { return nil }
        return range
    }

    // The editor reports changes from inside a SwiftUI update (updateUIView's text set, a resign), where an
    // observed write is not allowed.
    private func schedulePublish() {
        guard !isPublishScheduled else { return }
        isPublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.publish()
        }
    }

    private func publish() {
        isPublishScheduled = false
        let selected = (textView?.selectedRange.length ?? 0) > 0
        if hasSelection != selected { hasSelection = selected }
        let note = nothingToRunState == nil ? nil : Self.nothingToRunMessage
        if runNote != note { runNote = note }
    }
}
