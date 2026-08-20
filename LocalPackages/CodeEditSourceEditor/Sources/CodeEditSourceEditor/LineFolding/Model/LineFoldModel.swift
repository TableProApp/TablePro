//
//  LineFoldModel.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/7/25.
//

import AppKit
import CodeEditTextView
import Combine

/// This object acts as the conductor between the line folding components.
///
/// This receives text changed events, and notifies the line fold calculator.
/// It then receives fold calculation updates, and notifies the drawing view.
/// It manages a cache of fold ranges for drawing.
///
/// For fold storage and querying, see ``LineFoldStorage``. For fold calculation see ``LineFoldCalculator``
/// and ``LineFoldProvider``. For drawing see ``LineFoldRibbonView``.
@MainActor
class LineFoldModel: NSObject, NSTextStorageDelegate, ObservableObject {
    static let emphasisId = "lineFolding"

    /// An ordered tree of fold ranges in a document. Can be traversed using ``FoldRange/parent``
    /// and ``FoldRange/subFolds``.
    @Published var foldCache: LineFoldStorage = LineFoldStorage(documentLength: 0)
    private var calculator: LineFoldCalculator

    private var textChangedStream: AsyncStream<Void>
    private var textChangedStreamContinuation: AsyncStream<Void>.Continuation
    private var cacheListenTask: Task<Void, Never>?
    private var pendingRestoreRanges: Set<Range<Int>>?
    private var placeholderTracker: LineFoldPlaceholderTracker?

    weak var controller: TextViewController?
    weak var foldView: NSView?

    init(controller: TextViewController, foldView: NSView) {
        self.controller = controller
        self.foldView = foldView
        (textChangedStream, textChangedStreamContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.calculator = LineFoldCalculator(
            foldProvider: controller.foldProvider,
            controller: controller,
            textChangedStream: textChangedStream
        )
        super.init()
        controller.textView.addStorageDelegate(self)

        let calculator = self.calculator
        cacheListenTask = Task { @MainActor [weak self, weak foldView] in
            for await newFolds in await calculator.valueStream {
                guard let self else { return }
                self.foldCache = newFolds
                foldView?.needsDisplay = true
                self.applyPendingRestoreIfPossible()
            }
        }
        textChangedStreamContinuation.yield(Void())
        placeholderTracker = LineFoldPlaceholderTracker(model: self)
    }

    func getFolds(in range: Range<Int>) -> [FoldRange] {
        foldCache.folds(in: range)
    }

    /// Drops every fold the outgoing document had.
    ///
    /// A recalculation deliberately carries collapse state across by depth and start offset, which is what keeps a
    /// region folded while the reader types above it. Replacing the document makes those offsets meaningless, so
    /// without this one document's collapsed regions reappear in the next wherever they happen to line up.
    ///
    /// Nothing is posted. This is not the reader collapsing or expanding anything, and there is no document left for
    /// a listener to describe.
    func documentDidReplace() {
        gutterHover = nil
        placeholderHover = nil
        hoveredFold = nil
        foldCache = LineFoldStorage(documentLength: controller?.textView.documentRange.length ?? 0)
        pendingRestoreRanges = nil
        refresh()
    }

    /// Releases what outlives the view hierarchy on its own.
    ///
    /// The pointer tracking's area names this model's tracker as its owner and must not outlive it, and the task
    /// listening to the calculator awaits a stream that never ends, so neither is released by the editor's views
    /// going away.
    func destroy() {
        placeholderTracker?.destroy()
        placeholderTracker = nil
        cacheListenTask?.cancel()
        cacheListenTask = nil
    }

    // MARK: - Collapse

    /// Collapses or expands a fold, adding or removing its placeholder to match.
    func setCollapsed(_ isCollapsed: Bool, for fold: FoldRange) {
        guard let controller, let layoutManager = controller.textView?.layoutManager else { return }
        guard isCollapsed != self.isCollapsed(fold) else { return }

        if isCollapsed {
            guard let placeholder = makePlaceholder(for: fold, controller: controller) else { return }
            layoutManager.attachments.add(placeholder, for: NSRange(fold.range))
        } else if let attachment = attachment(for: fold) {
            layoutManager.attachments.remove(atOffset: attachment.range.location)
        }

        commitCollapseChange(for: fold)
    }

    /// The single place a fold's collapsed state is recorded and published.
    ///
    /// Every route that collapses or expands a fold ends here, so the cache, the layout, the gutter and anything
    /// listening for the notification can never disagree about what is folded. The two routes differ only in who
    /// removes the placeholder: the gutter's chevron asks the layout manager to, and a click on the placeholder has
    /// already had it removed by the attachment manager before the delegate is told.
    private func commitCollapseChange(for fold: FoldRange) {
        foldCache.toggleCollapse(forFold: fold)
        controller?.textView?.needsLayout = true
        controller?.gutterView?.needsDisplay = true
        foldView?.needsDisplay = true
        guard let controller else { return }
        NotificationCenter.default.post(
            name: TextViewController.foldStateDidChangeNotification,
            object: controller
        )
    }

    /// Collapses or expands every fold at once.
    ///
    /// Collapsing is limited to the outermost folds because the layout manager ignores an attachment that overlaps an
    /// earlier one, so collapsing a fold and its children together would leave the children's placeholders unlaid out.
    func setAllCollapsed(_ isCollapsed: Bool) {
        guard let controller else { return }
        let documentRange = controller.textView.documentRange.intRange
        let folds = foldCache.folds(in: documentRange)
        guard let minimumDepth = folds.map(\.depth).min() else { return }

        let targets = isCollapsed ? folds.filter { $0.depth == minimumDepth } : folds.reversed()
        for fold in targets {
            setCollapsed(isCollapsed, for: fold)
        }
    }

    func isCollapsed(_ fold: FoldRange) -> Bool {
        foldCache.isCollapsed(fold.id) ?? fold.isCollapsed
    }

    func collapsedFoldRanges() -> [Range<Int>] {
        guard let controller else { return [] }
        return foldCache
            .folds(in: controller.textView.documentRange.intRange)
            .filter(\.isCollapsed)
            .map(\.range)
    }

    /// Queues ranges to collapse once the fold cache next reports folds for them.
    func restoreCollapsedFolds(_ ranges: [Range<Int>]) {
        guard !ranges.isEmpty else { return }
        pendingRestoreRanges = Set(ranges)
        applyPendingRestoreIfPossible()
    }

    private func applyPendingRestoreIfPossible() {
        guard let pending = pendingRestoreRanges, let controller else { return }
        let folds = foldCache.folds(in: controller.textView.documentRange.intRange)
        guard !folds.isEmpty else { return }

        pendingRestoreRanges = nil
        for fold in folds where pending.contains(fold.range) && !fold.isCollapsed {
            setCollapsed(true, for: fold)
        }
    }

    // MARK: - Hover

    /// A collapsed fold the pointer is resting on, and where its placeholder is drawn.
    struct PlaceholderHover: Equatable {
        let fold: FoldRange
        let hit: CollapsedFoldHit
    }

    /// The fold the pointer is on, whichever of the two controls reports it.
    ///
    /// The gutter's chevron and the collapsed fold's placeholder are two views onto the same fold, and only one of
    /// them can be under the pointer. Both report here instead of each keeping its own idea of what is hovered, so
    /// pointing at either one lights up both.
    private(set) var hoveredFold: FoldRange?

    private var gutterHover: FoldRange?
    private var placeholderHover: PlaceholderHover?

    /// Reports the fold whose chevron the pointer is on, or `nil` when it is on none of them.
    func setGutterHover(_ fold: FoldRange?) {
        guard gutterHover?.id != fold?.id else { return }
        gutterHover = fold
        resolveHover()
    }

    /// Reports the collapsed fold whose placeholder the pointer is on, or `nil` when it is on none of them.
    ///
    /// Scrolling moves a placeholder out from under a stationary pointer, so this is compared on the whole hit
    /// rather than on the fold: a peek anchored to the old rect has to be told the anchor moved.
    func setPlaceholderHover(_ hover: PlaceholderHover?) {
        guard placeholderHover != hover else { return }
        placeholderHover = hover
        resolveHover()
        controller?.foldHoverDidChange(hover?.hit)
    }

    private func resolveHover() {
        let resolved = placeholderHover?.fold ?? gutterHover
        guard resolved?.id != hoveredFold?.id else { return }
        hoveredFold = resolved
        foldView?.needsDisplay = true

        guard let resolved else {
            clearEmphasis()
            return
        }
        emphasizeBracketsForFold(resolved)
    }

    private func attachment(for fold: FoldRange) -> AnyTextAttachment? {
        guard let layoutManager = controller?.textView?.layoutManager,
              let firstLine = layoutManager.textLineForOffset(fold.range.lowerBound) else { return nil }
        return layoutManager.attachments
            .getAttachmentsStartingIn(NSRange(fold.range))
            .first {
                $0.attachment is LineFoldPlaceholder && firstLine.range.contains($0.range.location)
            }
    }

    private func makePlaceholder(for fold: FoldRange, controller: TextViewController) -> LineFoldPlaceholder? {
        guard let text = controller.textView.textStorage?.string as NSString?,
              let layoutManager = controller.textView?.layoutManager else { return nil }
        let startLine = layoutManager.textLineForOffset(fold.range.lowerBound)?.index ?? 0
        let endLine = layoutManager.textLineForOffset(max(fold.range.lowerBound, fold.range.upperBound - 1))?.index
            ?? startLine
        let summary = FoldPlaceholderSummary.summarize(
            content: text,
            foldRange: fold.range,
            hiddenLineCount: max(0, endLine - startLine)
        )

        return LineFoldPlaceholder(
            delegate: self,
            fold: fold,
            charWidth: controller.font.charWidth,
            label: controller.foldProvider.foldPlaceholderLabel(for: summary),
            font: controller.font
        )
    }

    /// Recomputes folds for the whole document. Used to catch up after the ribbon has been hidden and is shown again.
    func refresh() {
        textChangedStreamContinuation.yield()
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else {
            return
        }
        foldCache.storageUpdated(editedRange: editedRange, changeInLength: delta)
        // Recalculating folds walks the whole document. Skip it while the ribbon is hidden; `refresh()` rebuilds when
        // it is shown again.
        guard foldView?.isHidden != true else { return }
        textChangedStreamContinuation.yield()
    }

    /// Finds the deepest cached fold and depth of the fold for a line number.
    /// - Parameter lineNumber: The line number to query, zero-indexed.
    /// - Returns: The deepest cached fold and depth of the fold if it was found.
    func getCachedFoldAt(lineNumber: Int) -> FoldRange? {
        guard let lineRange = controller?.textView.layoutManager.textLineForIndex(lineNumber)?.range else { return nil }
        guard let deepestFold = foldCache.folds(in: lineRange.intRange).max(by: {
            if $0.isCollapsed != $1.isCollapsed {
                $1.isCollapsed // Collapsed folds take precedence.
            } else if $0.isCollapsed {
                $0.depth > $1.depth
            } else {
                $0.depth < $1.depth
            }
        }) else {
            return nil
        }
        return deepestFold
    }

    private func emphasizeBracketsForFold(_ fold: FoldRange) {
        clearEmphasis()

        // Find the text object, make sure there's available characters around the fold.
        guard let text = controller?.textView.textStorage.string as? NSString,
              fold.range.lowerBound > 0 && fold.range.upperBound < text.length - 1 else {
            return
        }

        let firstRange = NSRange(location: fold.range.lowerBound - 1, length: 1)
        let secondRange = NSRange(location: fold.range.upperBound, length: 1)

        // Check if these are emphasizable bracket pairs.
        guard BracketPairs.matches(text.substring(from: firstRange) ?? "")
                && BracketPairs.matches(text.substring(from: secondRange) ?? "") else {
            return
        }

        controller?.textView.emphasisManager?.addEmphases(
            [
                Emphasis(range: firstRange, style: .standard, flash: false, inactive: false, selectInDocument: false),
                Emphasis(range: secondRange, style: .standard, flash: false, inactive: false, selectInDocument: false),
            ],
            for: Self.emphasisId
        )
    }

    private func clearEmphasis() {
        controller?.textView.emphasisManager?.removeEmphases(for: Self.emphasisId)
    }
}

// MARK: - LineFoldPlaceholderDelegate

extension LineFoldModel: LineFoldPlaceholderDelegate {
    func placeholderBackgroundColor() -> NSColor {
        controller?.configuration.appearance.theme.invisibles.color ?? .lightGray
    }

    func placeholderTextColor() -> NSColor {
        controller?.configuration.appearance.theme.text.color.withAlphaComponent(0.35) ?? .tertiaryLabelColor
    }

    func placeholderSelectedColor() -> NSColor {
        .controlAccentColor
    }

    func placeholderSelectedTextColor() -> NSColor {
        controller?.theme.background ?? .controlBackgroundColor
    }

    func placeholderDiscarded(fold: FoldRange) {
        setPlaceholderHover(nil)
        commitCollapseChange(for: fold)
    }
}
