//
//  TextSelectionManager.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 7/17/23.
//

import AppKit

public protocol TextSelectionManagerDelegate: AnyObject {
    var visibleTextRange: NSRange? { get }

    func setNeedsDisplay()
    /// Redraws one part of the view, as `NSView.setNeedsDisplay(_:)` does.
    func setNeedsDisplay(_ invalidRect: NSRect)
    func estimatedLineHeight() -> CGFloat
}

/// Manages an array of text selections representing cursors (0-length ranges) and selections (>0-length ranges).
///
/// Draws selections using a draw method similar to the `TextLayoutManager` class, and adds cursor views when
/// appropriate.
public class TextSelectionManager: NSObject {
    // MARK: - Properties

    public static let selectionChangedNotification = Notification.Name("com.CodeEdit.TextSelectionManager.TextSelectionChangedNotification")

    /// `nil` leaves the caret to the system: an `NSTextInsertionIndicator` keeps its own color, and the drawn caret
    /// takes ``nativeInsertionPointColor``.
    public var insertionPointColor: NSColor? {
        didSet {
            for view in textSelections.compactMap(\.view) {
                if let cursorView = view as? CursorView {
                    cursorView.color = drawnInsertionPointColor
                } else if #available(macOS 14.0, *), let indicator = view as? NSTextInsertionIndicator {
                    indicator.color = insertionPointColor
                }
            }
        }
    }

    /// The color the system gives a caret: the Highlight color from macOS 14, the text color before it.
    public static var nativeInsertionPointColor: NSColor {
        if #available(macOS 14.0, *) {
            return .textInsertionPointColor
        }
        return .textColor
    }

    var drawnInsertionPointColor: NSColor {
        insertionPointColor ?? Self.nativeInsertionPointColor
    }

    public var highlightSelectedLine: Bool = true
    public var selectedLineBackgroundColor = NSColor.selectedTextBackgroundColor.withSystemEffect(.disabled)
    public var selectionBackgroundColor = NSColor.selectedTextBackgroundColor
    // A view that never takes focus, such as a theme preview, still shows the selection a focused one draws.
    public var drawsSelectionEmphasized = false {
        didSet {
            delegate?.setNeedsDisplay()
        }
    }
    public var useSystemCursor: Bool = false {
        didSet {
            updateSelectionViews()
        }
    }

    /// Determines how far inset to draw selection content.
    public var edgeInsets: HorizontalEdgeInsets = .zero {
        didSet {
            delegate?.setNeedsDisplay()
        }
    }

    public internal(set) var textSelections: [TextSelection] = []
    // Bumped on every announced change, so a kill can tell that nothing moved since the last one.
    public private(set) var changeCount = 0
    weak var layoutManager: TextLayoutManager?
    weak var textStorage: NSTextStorage?
    weak var textView: TextView?
    weak var delegate: TextSelectionManagerDelegate?
    var cursorTimer: CursorTimer
    // Where the selections last drew their caret line band or their fill, so a move redraws only there and where
    // they are now, the way `NSTextView` redraws only the lines an insertion point leaves and enters.
    private var drawnSelectionRects: [CGRect] = []

    public init(
        layoutManager: TextLayoutManager,
        textStorage: NSTextStorage,
        textView: TextView?,
        delegate: TextSelectionManagerDelegate?,
        useSystemCursor: Bool = false
    ) {
        self.layoutManager = layoutManager
        self.textStorage = textStorage
        self.textView = textView
        self.delegate = delegate
        self.cursorTimer = CursorTimer()
        super.init()
        textSelections = []
        updateSelectionViews()
    }

    // MARK: - Selected Ranges

    /// Set the selected ranges to a single range. Overrides any existing selections.
    /// - Parameter range: The range to set.
    public func setSelectedRange(_ range: NSRange) {
        textSelections.forEach { $0.view?.removeFromSuperview() }
        let range = range.clamped(toLength: textStorage?.length ?? 0)
        let selection = TextSelection(range: range)
        selection.suggestedXPos = layoutManager?.rectForOffset(range.location)?.minX
        textSelections = [selection]
        updateSelectionViews()
        setNeedsDisplayForSelections()
        notifySelectionChanged()
    }

    /// Set the selected ranges to new ranges. Overrides any existing selections.
    /// - Parameter range: The selected ranges to set.
    public func setSelectedRanges(_ ranges: [NSRange]) {
        let oldRanges = textSelections.map(\.range)

        textSelections.forEach { $0.view?.removeFromSuperview() }
        // Remove duplicates, drop malformed ranges, clamp stale ones, update suggested X position.
        // A negative location is malformed and is discarded. A location past the end is a stale but
        // well-formed range, which happens whenever the text shrinks under an existing selection;
        // clamping keeps a usable selection there instead of leaving the view with none at all.
        let storageLength = textStorage?.length ?? 0
        textSelections = Set(ranges.filter { $0.location >= 0 }.map { $0.clamped(toLength: storageLength) })
            .sorted(by: { $0.location < $1.location })
            .map {
                let selection = TextSelection(range: $0)
                selection.suggestedXPos = layoutManager?.rectForOffset($0.location)?.minX
                return selection
            }
        updateSelectionViews()
        setNeedsDisplayForSelections()

        if oldRanges != textSelections.map(\.range) {
            notifySelectionChanged()
        }
    }

    /// Append a new selected range to the existing ones.
    /// - Parameter range: The new range to add.
    public func addSelectedRange(_ range: NSRange) {
        let newTextSelection = TextSelection(range: range)
        var didHandle = false
        for textSelection in textSelections {
            if textSelection.range == newTextSelection.range {
                // Duplicate range, ignore
                return
            } else if (range.length > 0 && textSelection.range.intersection(range) != nil)
                        || textSelection.range.max == range.location {
                // Range intersects existing range, modify this range to be the union of both and don't add the new
                // selection
                textSelection.range = textSelection.range.union(range)
                didHandle = true
            }
        }
        if !didHandle {
            textSelections.append(newTextSelection)
            textSelections.sort(by: { $0.range.location < $1.range.location })
        }

        updateSelectionViews()
        notifySelectionChanged()
        setNeedsDisplayForSelections()
    }

    /// The single place a selection change is announced, to observers and to assistive clients alike.
    func notifySelectionChanged() {
        changeCount &+= 1
        NotificationCenter.default.post(Notification(name: Self.selectionChangedNotification, object: self))
        // Only the manager the text view answers to speaks for it. The minimap builds a second manager over the
        // same text view and mirrors every selection into it, which would announce each move twice.
        if let textView, textView.selectionManager === self {
            NSAccessibility.post(element: textView, notification: .selectedTextChanged)
        }
    }

    // MARK: - Selection Views

    /// Update all selection cursors. Placing them in the correct position for each text selection and
    /// optionally reseting the blink timer.
    func updateSelectionViews(force: Bool = false, skipTimerReset: Bool = false) {
        guard textView?.isFirstResponder ?? false else { return }
        // A selectable but non-editable view tracks a collapsed selection so the user can extend
        // it or select a word, but it must not blink an insertion point at text it cannot edit.
        // This mirrors `NSTextView` with `isEditable = false` and `isSelectable = true`.
        let showsInsertionPoint = textView?.isEditable ?? true
        var didUpdate: Bool = false

        for textSelection in textSelections {
            if textSelection.range.isEmpty {
                if showsInsertionPoint {
                    // Repositioned before the result is folded in, or every caret after the first that moved would
                    // keep its old place.
                    let didReposition = repositionCursorSelection(textSelection: textSelection)
                    didUpdate = didUpdate || didReposition
                } else if textSelection.view != nil {
                    textSelection.view?.removeFromSuperview()
                    textSelection.view = nil
                    didUpdate = true
                }
            } else if !textSelection.range.isEmpty && textSelection.view != nil {
                textSelection.view?.removeFromSuperview()
                textSelection.view = nil
                didUpdate = true
            }
        }

        if didUpdate || force {
            setNeedsDisplayForSelections()
            if !skipTimerReset {
                cursorTimer.resetTimer()
                resetSystemCursorTimers()
            }
        }
    }

    private func repositionCursorSelection(textSelection: TextSelection) -> Bool {
        guard let cursorRect = layoutManager?.rectForOffset(textSelection.range.location) else {
            return false
        }

        var doesViewNeedReposition: Bool

        // If using the system cursor, macOS will change the origin and height by about 0.5, so we do an
        // approximate equals in that case to avoid extra updates.
        if useSystemCursor, #available(macOS 14.0, *) {
            doesViewNeedReposition = !textSelection.boundingRect.origin.approxEqual(cursorRect.origin)
            || !textSelection.boundingRect.height.approxEqual(layoutManager?.estimateLineHeight() ?? 0)
        } else {
            doesViewNeedReposition = textSelection.boundingRect.origin != cursorRect.origin
            || textSelection.boundingRect.height != layoutManager?.estimateLineHeight() ?? 0
        }

        if textSelection.view == nil || doesViewNeedReposition {
            let cursorView: NSView

            if let existingCursorView = textSelection.view {
                cursorView = existingCursorView
            } else {
                textSelection.view?.removeFromSuperview()
                textSelection.view = nil

                if useSystemCursor, #available(macOS 14.0, *) {
                    let systemCursorView = NSTextInsertionIndicator(frame: .zero)
                    cursorView = systemCursorView
                    systemCursorView.displayMode = .automatic
                    if let insertionPointColor {
                        systemCursorView.color = insertionPointColor
                    }
                } else {
                    let internalCursorView = CursorView(color: drawnInsertionPointColor)
                    cursorView = internalCursorView
                    cursorTimer.register(internalCursorView)
                }

                textView?.addSubview(cursorView, positioned: .above, relativeTo: nil)
            }

            cursorView.frame.origin = cursorRect.origin
            cursorView.frame.size.height = cursorRect.height

            textSelection.view = cursorView
            textSelection.boundingRect = cursorView.frame

            return true
        }

        return false
    }

    private func resetSystemCursorTimers() {
        guard #available(macOS 14, *) else { return }
        for cursorView in textSelections.compactMap({ $0.view as? NSTextInsertionIndicator }) {
            let frame = cursorView.frame
            cursorView.frame = .zero
            cursorView.frame = frame
        }
    }

    /// Get the height for a cursor placed at the beginning of the given range.
    /// - Parameter range: The range the cursor is at.
    /// - Returns: The height the cursor should be to match the text at that location.
    fileprivate func heightForCursorAt(_ range: NSRange) -> CGFloat? {
        guard let selectedLine = layoutManager?.textLineForOffset(range.location) else {
            return layoutManager?.estimateLineHeight()
        }
        return selectedLine
            .data
            .lineFragments
            .getLine(atOffset: range.location - (selectedLine.range.location))?
            .height
        ?? layoutManager?.estimateLineHeight()
    }

    /// Removes all cursor views and stops the cursor blink timer.
    ///
    /// The view reference is cleared as well as detached: `updateSelectionViews` only
    /// re-adds a cursor on the `view == nil` branch, so leaving a dangling reference here
    /// meant the caret never came back after the text view resigned first responder.
    /// Redraws where the selections drew last time and where they draw now, and nothing else.
    ///
    /// A caret draws the band behind its whole line and a range fills the lines it covers, so each is bounded by the
    /// full width of those lines. The text under them is drawn by the line fragment views, which a move leaves alone.
    func setNeedsDisplayForSelections() {
        let current = selectionRects()
        guard let delegate else {
            drawnSelectionRects = current
            return
        }
        let dirty = drawnSelectionRects + current
        drawnSelectionRects = current
        guard dirty.count <= Self.separatelyInvalidatedRectLimit else {
            delegate.setNeedsDisplay(dirty.reduce(CGRect.null) { $0.union($1) })
            return
        }
        for rect in dirty {
            delegate.setNeedsDisplay(rect)
        }
    }

    // Past this many carets one rect covering them all costs AppKit less than tracking each one.
    private static let separatelyInvalidatedRectLimit = 64

    /// Remembers where a draw pass put the selections, which is not always where the last change left them: a layout
    /// pass can move their lines and redraw them there without any selection changing.
    func noteSelectionsDrawn(in rect: NSRect) {
        for drawn in selectionRects() where drawn.intersects(rect) && !drawnSelectionRects.contains(drawn) {
            drawnSelectionRects.append(drawn)
        }
        if drawnSelectionRects.count > Self.separatelyInvalidatedRectLimit {
            drawnSelectionRects = [drawnSelectionRects.reduce(CGRect.null) { $0.union($1) }]
        }
    }

    private func selectionRects() -> [CGRect] {
        guard let layoutManager else { return [] }
        let width = max(textView?.frame.width ?? 0, layoutManager.maxLineWidth + layoutManager.edgeInsets.horizontal)
        return textSelections.compactMap { selection in
            guard let first = layoutManager.textLineForOffset(selection.range.location) else { return nil }
            let last = selection.range.isEmpty
                ? first
                : layoutManager.textLineForOffset(selection.range.max) ?? first
            return CGRect(x: 0, y: first.yPos, width: width, height: last.yPos + last.height - first.yPos)
        }
    }

    func removeCursors() {
        cursorTimer.stopTimer()
        for textSelection in textSelections {
            textSelection.view?.removeFromSuperview()
            textSelection.view = nil
            textSelection.boundingRect = .zero
        }
    }
}
