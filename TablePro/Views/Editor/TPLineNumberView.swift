import AppKit
import os

/// Line number gutter using the standard NSRulerView mechanism.
///
/// Attaches to an NSScrollView as its vertical ruler and draws line numbers
/// alongside the text view. Observes text changes and scroll position to
/// keep line numbers accurate and performant.
///
/// Based on the proven approach from Sequel Ace's NoodleLineNumberView,
/// rewritten in Swift with current-line highlighting and O(1) string access.
final class TPLineNumberView: NSRulerView {
    // MARK: - Constants

    private static let logger = Logger(subsystem: "com.TablePro", category: "TPLineNumberView")
    private static let defaultThickness: CGFloat = 22.0
    private static let rulerMargin: CGFloat = 5.0
    private static let largeFileSizeThreshold = 3_000_000

    // MARK: - Configuration

    var font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) {
        didSet {
            updateFontMetrics()
            invalidateLineCache()
            needsDisplay = true
        }
    }

    var textColor = NSColor(calibratedWhite: 0.42, alpha: 1.0) {
        didSet { needsDisplay = true }
    }

    var currentLineTextColor: NSColor = .textColor {
        didSet { needsDisplay = true }
    }

    var backgroundColor: NSColor = .controlBackgroundColor {
        didSet { needsDisplay = true }
    }

    var currentLineHighlightColor = NSColor.textColor.withAlphaComponent(0.06) {
        didSet { needsDisplay = true }
    }

    // MARK: - Line Cache

    /// Cached UTF-16 character offsets where each line starts. Index 0 is always 0.
    private var lineStartOffsets: [Int] = [0]

    /// Cached line count used to detect when ruler thickness needs updating.
    private var cachedLineCount: Int = 1

    /// Length of text when the cache was last built, used to avoid redundant rebuilds.
    private var cachedTextLength: Int = 0

    // MARK: - Font Metrics Cache

    private var digitGlyphWidth: CGFloat = 8.0
    private var digitGlyphHeight: CGFloat = 12.0
    private var fontAscender: CGFloat = 10.0

    // MARK: - Drag State

    private var dragSelectionStartLine: Int?

    // MARK: - Computed

    private var textView: NSTextView? {
        scrollView?.documentView as? NSTextView
    }

    // MARK: - Initialization

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        commonInit()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("NSCoding is not supported")
    }

    private func commonInit() {
        clientView = scrollView?.documentView
        updateFontMetrics()
        ruleThickness = Self.defaultThickness

        let center = NotificationCenter.default

        if let textView {
            center.addObserver(
                self,
                selector: #selector(textDidChange(_:)),
                name: NSTextStorage.didProcessEditingNotification,
                object: textView.textStorage
            )
        }

        if let clipView = scrollView?.contentView {
            clipView.postsBoundsChangedNotifications = true
            clipView.postsFrameChangedNotifications = true

            center.addObserver(
                self,
                selector: #selector(viewBoundsOrFrameDidChange(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
            center.addObserver(
                self,
                selector: #selector(viewBoundsOrFrameDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: clipView
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }

    // MARK: - Notification Handlers

    @objc private func textDidChange(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage else { return }

        // Only rebuild if actual text content changed (not just attribute edits)
        let editedMask = storage.editedMask
        guard editedMask.contains(.editedCharacters) else {
            setNeedsDisplay(bounds)
            return
        }

        invalidateLineCache()
        setNeedsDisplay(bounds)
    }

    @objc private func viewBoundsOrFrameDidChange(_ notification: Notification) {
        setNeedsDisplay(bounds)
    }

    // MARK: - Line Cache Management

    private func invalidateLineCache() {
        cachedTextLength = -1
    }

    /// Rebuilds the line start offset cache by scanning the text for newline characters.
    /// Uses `(string as NSString)` for O(1) character access per the project performance rules.
    private func buildLineStartOffsets() {
        guard let textView else {
            lineStartOffsets = [0]
            cachedLineCount = 1
            cachedTextLength = 0
            return
        }

        let nsString = textView.string as NSString
        let length = nsString.length

        // Skip rebuild if text length hasn't changed since last cache
        guard length != cachedTextLength else { return }
        cachedTextLength = length

        // Performance guard: skip line numbering for very large files
        guard length <= Self.largeFileSizeThreshold else {
            Self.logger.warning("Text length \(length) exceeds threshold, skipping line cache rebuild")
            lineStartOffsets = [0]
            cachedLineCount = 1
            updateThicknessIfNeeded()
            return
        }

        // Pre-allocate with a reasonable estimate (average ~40 chars per line)
        var offsets: [Int] = []
        offsets.reserveCapacity(max(length / 40, 16))
        offsets.append(0)

        var index = 0
        while index < length {
            let char = nsString.character(at: index)
            index += 1
            if char == 0x0A { // \n
                offsets.append(index)
            } else if char == 0x0D { // \r
                // Handle \r\n as a single line break
                if index < length, nsString.character(at: index) == 0x0A {
                    index += 1
                }
                offsets.append(index)
            }
        }

        lineStartOffsets = offsets
        cachedLineCount = offsets.count
        updateThicknessIfNeeded()
    }

    // MARK: - Thickness Management

    override var requiredThickness: CGFloat {
        requiredThickness(forLineCount: cachedLineCount)
    }

    private func requiredThickness(forLineCount lineCount: Int) -> CGFloat {
        let digits = lineCount > 0 ? digitCount(lineCount) : 1
        let width = CGFloat(digits) * digitGlyphWidth + Self.rulerMargin * 2
        return ceil(max(Self.defaultThickness, width))
    }

    private func updateThicknessIfNeeded() {
        let newThickness = requiredThickness(forLineCount: cachedLineCount)
        guard ruleThickness != newThickness else { return }

        // Defer the resize to avoid changing view geometry during layout/display
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(applyRuleThickness(_:)),
            object: nil
        )
        perform(#selector(applyRuleThickness(_:)), with: NSNumber(value: Double(newThickness)), afterDelay: 0.0)
    }

    @objc private func applyRuleThickness(_ thickness: NSNumber) {
        ruleThickness = CGFloat(thickness.doubleValue)
    }

    // MARK: - Drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        // Ensure the line cache is current
        buildLineStartOffsets()

        guard cachedLineCount > 0 else { return }

        let bounds = self.bounds

        // Fill background
        backgroundColor.setFill()
        rect.fill()

        // Draw a subtle right-edge separator line
        let separatorColor = NSColor.separatorColor
        separatorColor.setStroke()
        let separatorPath = NSBezierPath()
        separatorPath.move(to: NSPoint(x: bounds.maxX - 0.5, y: rect.minY))
        separatorPath.line(to: NSPoint(x: bounds.maxX - 0.5, y: rect.maxY))
        separatorPath.lineWidth = 1.0
        separatorPath.stroke()

        // Get visible rect in the text view's coordinate space
        guard let clipView = scrollView?.contentView else { return }
        let visibleRect = clipView.bounds
        let yOffset = textView.textContainerInset.height

        // Determine the current line (where the insertion point is)
        let currentLineIndex = lineIndex(forCharacterIndex: textView.selectedRange().location)

        // Get the visible glyph range
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textContainer
        )

        guard visibleGlyphRange.location != NSNotFound else { return }

        // Convert to character range
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange,
            actualGlyphRange: nil
        )

        // Find the first visible line using binary search
        let firstVisibleLine = lineIndex(forCharacterIndex: visibleCharRange.location)

        // Pre-build text attributes
        let normalAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor
        ]
        let currentLineAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: currentLineTextColor
        ]

        let drawableWidth = bounds.width - Self.rulerMargin * 2

        // Iterate through visible lines
        for line in firstVisibleLine..<cachedLineCount {
            let charIndex = lineStartOffsets[line]

            // Stop if we've gone past the visible range (with a small fudge factor)
            if charIndex > NSMaxRange(visibleCharRange) + 1 {
                break
            }

            // Get the glyph index for this character position
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(charIndex, max(0, layoutManager.numberOfGlyphs - 1)))

            // Get the line fragment rect for this glyph
            var effectiveRange = NSRange(location: NSNotFound, length: 0)
            let lineFragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: &effectiveRange
            )

            // Only draw the line number for the first fragment of wrapped lines.
            // If effectiveRange starts before our glyph, this is a continuation fragment.
            if effectiveRange.location != glyphIndex {
                // Check if this character actually starts a new line
                let effectiveCharIndex = layoutManager.characterIndexForGlyph(at: effectiveRange.location)
                if effectiveCharIndex != charIndex {
                    continue
                }
            }

            // Convert Y from text view coordinates to ruler coordinates
            let lineY = lineFragmentRect.origin.y + yOffset - visibleRect.origin.y
            let lineHeight = lineFragmentRect.height

            let isCurrentLine = line == currentLineIndex

            // Draw current line highlight background in the gutter
            if isCurrentLine {
                currentLineHighlightColor.setFill()
                let highlightRect = NSRect(
                    x: 0,
                    y: lineY,
                    width: bounds.width - 1.0,
                    height: lineHeight
                )
                highlightRect.fill()
            }

            // Format line number (1-based)
            let lineNumberString = "\(line + 1)" as NSString
            let attributes = isCurrentLine ? currentLineAttributes : normalAttributes

            // Calculate position: right-aligned with margin
            let stringSize = lineNumberString.size(withAttributes: attributes)
            let xPosition = Self.rulerMargin + drawableWidth - stringSize.width
            let yPosition = lineY + (lineHeight - digitGlyphHeight) / 2.0

            lineNumberString.draw(
                at: NSPoint(x: xPosition, y: yPosition),
                withAttributes: attributes
            )
        }
    }

    // MARK: - Line Index Lookup

    /// Binary search to find the 0-based line index for a given UTF-16 character index.
    private func lineIndex(forCharacterIndex charIndex: Int) -> Int {
        // Ensure cache is current
        buildLineStartOffsets()

        var low = 0
        var high = lineStartOffsets.count

        while high - low > 1 {
            let mid = (low + high) >> 1
            let midOffset = lineStartOffsets[mid]

            if charIndex < midOffset {
                high = mid
            } else if charIndex > midOffset {
                low = mid
            } else {
                return mid
            }
        }
        return low
    }

    /// Returns the 1-based line number for a Y location in the ruler view's coordinate space.
    /// Returns nil if the location doesn't correspond to a visible line.
    private func lineNumber(forLocation location: CGFloat) -> Int? {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let clipView = scrollView?.contentView else {
            return nil
        }

        let visibleRect = clipView.bounds
        let adjustedLocation = location + visibleRect.origin.y

        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textContainer
        )
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange,
            actualGlyphRange: nil
        )

        // Fudge the range slightly for trailing newlines
        let extendedRange = NSRange(
            location: visibleCharRange.location,
            length: visibleCharRange.length + 1
        )

        let yOffset = textView.textContainerInset.height
        let firstVisibleLine = lineIndex(forCharacterIndex: visibleCharRange.location)

        for line in firstVisibleLine..<cachedLineCount {
            let charIndex = lineStartOffsets[line]
            guard NSLocationInRange(charIndex, extendedRange) || charIndex <= NSMaxRange(extendedRange) else {
                continue
            }

            if charIndex > NSMaxRange(extendedRange) {
                break
            }

            var rectCount: Int = 0
            let rects = layoutManager.rectArray(
                forCharacterRange: NSRange(location: charIndex, length: 0),
                withinSelectedCharacterRange: NSRange(location: NSNotFound, length: 0),
                in: textContainer,
                rectCount: &rectCount
            )

            guard rectCount > 0, let firstRect = rects else { continue }

            let rectY = firstRect.pointee.origin.y + yOffset
            let rectHeight = firstRect.pointee.height

            if adjustedLocation >= rectY && adjustedLocation < rectY + rectHeight {
                return line + 1 // 1-based
            }
        }
        return nil
    }

    // MARK: - Click to Select Line

    override func mouseDown(with event: NSEvent) {
        guard let textView else { return }

        let location = convert(event.locationInWindow, from: nil).y
        guard let line = lineNumber(forLocation: location) else { return }

        dragSelectionStartLine = line
        selectLines(from: line, to: line, in: textView)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let textView,
              let startLine = dragSelectionStartLine else {
            return
        }

        let location = convert(event.locationInWindow, from: nil).y
        guard let currentLine = lineNumber(forLocation: location) else { return }

        let fromLine = min(startLine, currentLine)
        let toLine = max(startLine, currentLine)
        selectLines(from: fromLine, to: toLine, in: textView)
        textView.autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragSelectionStartLine = nil
    }

    /// Selects the range of text spanning from the start of `fromLine` to the end of `toLine`.
    /// Lines are 1-based.
    private func selectLines(from fromLine: Int, to toLine: Int, in textView: NSTextView) {
        let lineCount = lineStartOffsets.count
        guard fromLine >= 1, fromLine <= lineCount else { return }

        let startOffset = lineStartOffsets[fromLine - 1]
        let endOffset: Int
        if toLine < lineCount {
            endOffset = lineStartOffsets[toLine]
        } else {
            endOffset = (textView.string as NSString).length
        }

        let range = NSRange(location: startOffset, length: endOffset - startOffset)
        textView.setSelectedRange(range)
    }

    // MARK: - Font Metrics

    private func updateFontMetrics() {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let sampleSize = ("8" as NSString).size(withAttributes: attributes)
        digitGlyphWidth = sampleSize.width
        digitGlyphHeight = sampleSize.height
        fontAscender = font.ascender
    }

    // MARK: - Utilities

    /// Returns the number of decimal digits in a positive integer.
    private func digitCount(_ value: Int) -> Int {
        guard value > 0 else { return 1 }
        var count = 0
        var remaining = value
        while remaining > 0 {
            count += 1
            remaining /= 10
        }
        return count
    }
}
