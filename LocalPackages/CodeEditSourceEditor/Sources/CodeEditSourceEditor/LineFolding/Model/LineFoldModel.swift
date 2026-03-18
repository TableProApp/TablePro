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
class LineFoldModel: NSObject, NSTextStorageDelegate, ObservableObject {
    static let emphasisId = "lineFolding"

    /// An ordered tree of fold ranges in a document. Can be traversed using ``FoldRange/parent``
    /// and ``FoldRange/subFolds``.
    @Published var foldCache: LineFoldStorage = LineFoldStorage(documentLength: 0)
    private var calculator: LineFoldCalculator

    private var textChangedStream: AsyncStream<Void>
    private var textChangedStreamContinuation: AsyncStream<Void>.Continuation
    private var cacheListenTask: Task<Void, Never>?

    weak var controller: TextViewController?
    weak var foldView: NSView?

    init(controller: TextViewController, foldView: NSView) {
        self.controller = controller
        self.foldView = foldView
        (textChangedStream, textChangedStreamContinuation) = AsyncStream<Void>.makeStream()
        self.calculator = LineFoldCalculator(
            foldProvider: controller.foldProvider,
            controller: controller,
            textChangedStream: textChangedStream
        )
        super.init()
        controller.textView.addStorageDelegate(self)

        cacheListenTask = Task { @MainActor [weak foldView] in
            for await newFolds in await calculator.valueStream {
                foldCache = newFolds
                foldView?.needsDisplay = true
            }
        }
        textChangedStreamContinuation.yield(Void())
    }

    func getFolds(in range: Range<Int>) -> [FoldRange] {
        foldCache.folds(in: range)
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
        textChangedStreamContinuation.yield()
    }

    /// Finds the deepest cached depth of the fold for a line number.
    /// - Parameter lineNumber: The line number to query, zero-indexed.
    /// - Returns: The deepest cached depth of the fold if it was found.
    func getCachedDepthAt(lineNumber: Int) -> Int? {
        return getCachedFoldAt(lineNumber: lineNumber)?.depth
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

    func emphasizeBracketsForFold(_ fold: FoldRange) {
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

    func clearEmphasis() {
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
        foldCache.toggleCollapse(forFold: fold)
        foldView?.needsDisplay = true
        textChangedStreamContinuation.yield()
    }
}
