import AppKit
import os

/// NSTextView subclass for SQL editing.
/// Minimal overrides — most behavior delegated to TPEditorDelegate.
final class TPTextView: NSTextView {
    private static let logger = Logger(subsystem: "com.TablePro", category: "TPTextView")

    // MARK: - External Interface

    weak var editorDelegate: TPEditorDelegate?

    /// When true, drawInsertionPoint draws nothing (VimCursorManager handles it via CALayer).
    var suppressSystemCursor = false

    // MARK: - Private State

    private var currentConfiguration: TPEditorConfiguration?

    // MARK: - Setup

    /// Configure the text view for code editing. Call once after TextKit stack is assembled externally.
    func configureForCodeEditing(configuration: TPEditorConfiguration) {
        currentConfiguration = configuration

        // Undo support
        allowsUndo = true

        // Disable macOS "smart" text behaviors that break code editing
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isGrammarCheckingEnabled = false
        isContinuousSpellCheckingEnabled = false
        smartInsertDeleteEnabled = false

        // Plain text mode — syntax colors applied via temporary attributes on NSLayoutManager
        isRichText = false

        // Built-in Find Bar (Cmd+F just works)
        usesFindBar = true
        isIncrementalSearchingEnabled = true

        // Large file performance
        layoutManager?.allowsNonContiguousLayout = true

        // Apply font, colors, scroll mode
        applyConfiguration(configuration)
        configureScrollMode(wrapLines: configuration.wrapLines)

        Self.logger.debug("Configured for code editing")
    }

    /// Apply a new configuration. Safe to call on every settings change.
    func applyConfiguration(_ configuration: TPEditorConfiguration) {
        currentConfiguration = configuration

        font = configuration.font
        isEditable = configuration.isEditable
        textContainerInset = NSSize(
            width: configuration.contentInsets.left,
            height: configuration.contentInsets.top
        )

        applyTheme(configuration.theme)
    }

    /// Apply only theme colors (faster path for theme-only changes).
    func applyTheme(_ theme: TPEditorTheme) {
        backgroundColor = theme.background
        textColor = theme.text
        insertionPointColor = theme.cursor
        selectedTextAttributes = [
            .backgroundColor: theme.selection
        ]
    }

    /// Configure horizontal scrolling vs. line wrapping using Apple's documented pattern.
    func configureScrollMode(wrapLines: Bool) {
        if wrapLines {
            textContainer?.widthTracksTextView = true
            textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            isHorizontallyResizable = false
            enclosingScrollView?.hasHorizontalScroller = false
        } else {
            textContainer?.widthTracksTextView = false
            textContainer?.size = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            isHorizontallyResizable = true
            enclosingScrollView?.hasHorizontalScroller = true
        }
    }

    // MARK: - Programmatic Text Changes

    /// Replace the entire content, preserving undo grouping correctly.
    func setContent(_ text: String) {
        let currentText = string

        // O(1) length check before expensive full comparison
        let currentLength = (currentText as NSString).length
        let newLength = (text as NSString).length
        if currentLength == newLength, currentText == text {
            return
        }

        let fullRange = NSRange(location: 0, length: currentLength)
        if shouldChangeText(in: fullRange, replacementString: text) {
            replaceCharacters(in: fullRange, with: text)
            didChangeText()
        }
    }

    // MARK: - NSTextView Overrides

    override func keyDown(with event: NSEvent) {
        if let delegate = editorDelegate, delegate.editorDidReceiveKeyDown(self, event: event) {
            return
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        guard let config = currentConfiguration, config.autoIndent else {
            super.insertNewline(sender)
            return
        }

        let nsString = string as NSString
        let selectedRange = selectedRange()
        let lineRange = nsString.lineRange(for: NSRange(location: selectedRange.location, length: 0))
        let lineText = nsString.substring(with: lineRange)

        // Extract leading whitespace from current line
        var leadingWhitespace = ""
        for character in lineText {
            if character == " " || character == "\t" {
                leadingWhitespace.append(character)
            } else {
                break
            }
        }

        let insertion = "\n" + leadingWhitespace
        let insertRange = selectedRange
        if shouldChangeText(in: insertRange, replacementString: insertion) {
            replaceCharacters(in: insertRange, with: insertion)
            didChangeText()
        }
    }

    override func insertTab(_ sender: Any?) {
        let tabString = tabStopString()
        let insertRange = selectedRange()
        if shouldChangeText(in: insertRange, replacementString: tabString) {
            replaceCharacters(in: insertRange, with: tabString)
            didChangeText()
        }
    }

    override func insertBacktab(_ sender: Any?) {
        let nsString = string as NSString
        let selectedRange = selectedRange()
        let lineRange = nsString.lineRange(for: NSRange(location: selectedRange.location, length: 0))
        let lineText = nsString.substring(with: lineRange)

        let tabWidth = currentConfiguration?.tabWidth ?? 4

        // Count leading spaces to remove (up to one tab stop)
        var spacesToRemove = 0
        for character in lineText {
            if character == " ", spacesToRemove < tabWidth {
                spacesToRemove += 1
            } else if character == "\t", spacesToRemove == 0 {
                spacesToRemove = 1
                break
            } else {
                break
            }
        }

        guard spacesToRemove > 0 else { return }

        let removeRange = NSRange(location: lineRange.location, length: spacesToRemove)
        if shouldChangeText(in: removeRange, replacementString: "") {
            replaceCharacters(in: removeRange, with: "")
            didChangeText()

            // Adjust cursor position
            let newCursorLocation = max(selectedRange.location - spacesToRemove, lineRange.location)
            setSelectedRange(NSRange(location: newCursorLocation, length: 0))
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if suppressSystemCursor {
            return
        }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            editorDelegate?.editorDidBecomeFirstResponder(self)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            editorDelegate?.editorDidResignFirstResponder(self)
        }
        return result
    }

    // MARK: - Private

    private func tabStopString() -> String {
        let tabWidth = currentConfiguration?.tabWidth ?? 4
        return String(repeating: " ", count: tabWidth)
    }
}
