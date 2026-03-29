//
//  TextView.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 6/21/23.
//

import AppKit
import TextStory

/// # Text View
///
/// A view that draws and handles user interactions with text.
/// Optimized for line-based documents, does not attempt to have feature parity with `NSTextView`.
///
/// The text view maintains multiple helper classes for selecting, editing, and laying out text.
/// ```
/// TextView
/// |-> NSTextStorage              Base text storage.
/// |-> TextLayoutManager          Creates, manages, and lays out text lines.
/// |  |-> TextLineStorage         Extremely fast object for storing and querying lines of text. Does not store text.
/// |  |-> [TextLine]              Represents a line of text.
/// |  |   |-> Typesetter          Calculates line breaks and other layout information for text lines.
/// |  |   |-> [LineFragment]      Represents a visual line of text, stored in an internal line storage object.
/// |  |-> [LineFragmentView]      Reusable line fragment view that draws a line fragment.
/// |  |-> MarkedRangeManager      Manages marked ranges, updates layout if needed.
/// |
/// |-> TextSelectionManager       Maintains, modifies, and renders text selections
/// |  |-> [TextSelection]         Represents a range of selected text.
/// ```
///
/// Conforms to [`NSTextContent`](https://developer.apple.com/documentation/appkit/nstextcontent) and
/// [`NSTextInputClient`](https://developer.apple.com/documentation/appkit/nstextinputclient) to work well with system
/// text interactions such as inserting text and marked text.
///
open class TextView: NSView, NSTextContent {
    // MARK: - Statics

    /// The default typing attributes:
    /// - font: System font, size 12
    /// - foregroundColor: System text color
    /// - kern: 0.0
    public static var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.textColor, .kern: 0.0]
    }

    // swiftlint:disable:next line_length
    public static let textDidChangeNotification: Notification.Name = .init(rawValue: "com.CodeEdit.TextView.TextDidChangeNotification")

    // swiftlint:disable:next line_length
    public static let textWillChangeNotification: Notification.Name = .init(rawValue: "com.CodeEdit.TextView.TextWillChangeNotification")

    // MARK: - Configuration

    /// The string for the text view.
    public var string: String {
        get {
            textStorage.string
        }
        set {
            textStorage.setAttributedString(NSAttributedString(string: newValue, attributes: typingAttributes))
        }
    }

    /// The attributes to apply to inserted text.
    public var typingAttributes: [NSAttributedString.Key: Any] = [:] {
        didSet {
            setNeedsDisplay()
            layoutManager?.setNeedsLayout()
        }
    }

    /// The default font of the text view.
    /// - Note: Setting the font for the text view will update the font as the user types. To change the font for the
    ///         entire view, update the `font` attribute in ``TextView/textStorage``.
    public var font: NSFont {
        get {
            (typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 12)
        }
        set {
            typingAttributes[.font] = newValue
            layoutManager?.setNeedsLayout()
            setNeedsDisplay()
        }
    }

    /// The text color of the text view.
    /// - Note: Setting the text color for the text view will update the text color as the user types. To change the
    ///         text color for the entire view, update the `foregroundColor` attribute in ``TextView/textStorage``.
    public var textColor: NSColor {
        get {
            (typingAttributes[.foregroundColor] as? NSColor) ?? NSColor.textColor
        }
        set {
            typingAttributes[.foregroundColor] = newValue
        }
    }

    /// The line height as a multiple of the font's line height. 1.0 represents no change in height.
    public var lineHeight: CGFloat {
        get {
            layoutManager?.lineHeightMultiplier ?? 1.0
        }
        set {
            layoutManager?.lineHeightMultiplier = newValue
        }
    }

    /// The amount of extra space to add when overscroll is enabled, as a percentage of the viewport height
    public var overscrollAmount: CGFloat = 0.5 {
        didSet {
            if overscrollAmount < 0 {
                overscrollAmount = 0
            }
            updateFrameIfNeeded()
        }
    }

    /// Whether or not the editor should wrap lines
    public var wrapLines: Bool {
        get {
            layoutManager?.wrapLines ?? false
        }
        set {
            layoutManager?.wrapLines = newValue
        }
    }

    /// A multiplier that determines the amount of space between characters. `1.0` indicates no space,
    /// `2.0` indicates one character of space between other characters.
    public var letterSpacing: Double {
        didSet {
            kern = fontCharWidth * (letterSpacing - 1.0)
            layoutManager.setNeedsLayout()
        }
    }

    /// Determines if the text view's content can be edited.
    public var isEditable: Bool {
        didSet {
            setNeedsDisplay()
            selectionManager.updateSelectionViews()
            if !isEditable && isFirstResponder {
                _ = resignFirstResponder()
            }
        }
    }

    /// Determines if the text view responds to selection events, such as clicks.
    public var isSelectable: Bool = true {
        didSet {
            if !isSelectable {
                selectionManager.removeCursors()
                if isFirstResponder {
                    _ = resignFirstResponder()
                }
            }
            setNeedsDisplay()
        }
    }

    /// The edge insets for the text view. This value insets every piece of drawable content in the view, including
    /// selection rects.
    ///
    /// To further inset the text from the edge, without modifying how selections are inset, use ``textInsets``
    public var edgeInsets: HorizontalEdgeInsets {
        get {
            selectionManager.edgeInsets
        }
        set {
            layoutManager.edgeInsets = newValue + textInsets
            selectionManager.edgeInsets = newValue
        }
    }

    /// Insets just drawn text from the horizontal edges. This is in addition to the insets in ``edgeInsets``, but does
    /// not apply to other drawn content.
    public var textInsets: HorizontalEdgeInsets {
        get {
            layoutManager.edgeInsets - selectionManager.edgeInsets
        }
        set {
            layoutManager.edgeInsets = edgeInsets + newValue
        }
    }

    /// The kern to use for characters. Defaults to `0.0` and is updated when `letterSpacing` is set.
    /// - Note: Setting the kern for the text view will update the kern as the user types. To change the
    ///         kern for the entire view, update the `kern` attribute in ``TextView/textStorage``.
    public var kern: CGFloat {
        get {
            typingAttributes[.kern] as? CGFloat ?? 0
        }
        set {
            typingAttributes[.kern] = newValue
        }
    }

    /// The strategy to use when breaking lines. Defaults to ``LineBreakStrategy/word``.
    public var lineBreakStrategy: LineBreakStrategy {
        get {
            layoutManager?.lineBreakStrategy ?? .word
        }
        set {
            layoutManager.lineBreakStrategy = newValue
        }
    }

    /// Determines if the text view uses the macOS system cursor or a ``CursorView`` for cursors.
    ///
    /// - Important: Only available after macOS 14.
    public var useSystemCursor: Bool {
        get {
            selectionManager?.useSystemCursor ?? false
        }
        set {
            guard #available(macOS 14, *) else {
                logger.warning("useSystemCursor only available after macOS 14.")
                return
            }
            selectionManager?.useSystemCursor = newValue
        }
    }

    /// The attributes used to render marked text.
    /// Defaults to a single underline.
    public var markedTextAttributes: [NSAttributedString.Key: Any] {
        get {
            layoutManager.markedTextManager.markedTextAttributes
        }
        set {
            layoutManager.markedTextManager.markedTextAttributes = newValue
            layoutManager.layoutLines() // Layout lines to refresh attributes. This should be rare.
        }
    }

    open var contentType: NSTextContentType?

    /// The text view's delegate.
    public weak var delegate: TextViewDelegate?

    /// The text storage object for the text view.
    /// - Warning: Do not update the text storage object directly. Doing so will very likely break the text view's
    ///            layout system. Use methods like ``TextView/replaceCharacters(in:with:)-58mt7`` or
    ///            ``TextView/insertText(_:)`` to modify content.
    package(set) public var textStorage: NSTextStorage!

    /// The layout manager for the text view.
    package(set) public var layoutManager: TextLayoutManager!

    /// The selection manager for the text view.
    package(set) public var selectionManager: TextSelectionManager!

    /// Manages emphasized text ranges in the text view
    public var emphasisManager: EmphasisManager?

    // MARK: - Private Properties

    var isFirstResponder: Bool = false

    /// When dragging to create a selection, these enable us to scroll the view as the user drags outside the view's
    /// bounds.
    var mouseDragAnchor: CGPoint?
    var mouseDragTimer: Timer?
    var cursorSelectionMode: CursorSelectionMode = .character

    /// When we receive a drag operation we add a temporary cursor view not managed by the selection manager.
    /// This is the reference to that view, it is cleaned up when a drag ends.
    var draggingCursorView: NSView?
    var isDragging: Bool = false

    var isOptionPressed: Bool = false

    private var fontCharWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: font]).width
    }

    internal(set) public var _undoManager: CEUndoManager?

    @objc dynamic open var allowsUndo: Bool

    var scrollView: NSScrollView? {
        guard let enclosingScrollView, enclosingScrollView.documentView == self else { return nil }
        return enclosingScrollView
    }

    var storageDelegate: MultiStorageDelegate!

    // MARK: - Init

    /// Initializes the text view.
    /// - Parameters:
    ///   - string: The contents of the text view.
    ///   - font: The default font.
    ///   - textColor: The default text color.
    ///   - lineHeightMultiplier: The multiplier to use for line heights.
    ///   - wrapLines: Determines how the view will wrap lines to the viewport.
    ///   - isEditable: Determines if the view is editable.
    ///   - isSelectable: Determines if the view is selectable.
    ///   - letterSpacing: Sets the letter spacing on the view.
    ///   - useSystemCursor: Set to true to use the system cursor. Only available in macOS >= 14.
    ///   - delegate: The text view's delegate.
    public init(
        string: String,
        font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular),
        textColor: NSColor = .labelColor,
        lineHeightMultiplier: CGFloat = 1.0,
        wrapLines: Bool = true,
        isEditable: Bool = true,
        isSelectable: Bool = true,
        letterSpacing: Double = 1.0,
        useSystemCursor: Bool = false,
        delegate: TextViewDelegate? = nil
    ) {
        self.textStorage = NSTextStorage(string: string)
        self.delegate = delegate
        self.isEditable = isEditable
        self.isSelectable = isSelectable
        self.letterSpacing = letterSpacing
        self.allowsUndo = true

        super.init(frame: .zero)

        self.emphasisManager = EmphasisManager(textView: self)
        if let storageDelegate = textStorage.delegate as? MultiStorageDelegate {
            self.storageDelegate = storageDelegate
        } else {
            self.storageDelegate = MultiStorageDelegate()
        }

        wantsLayer = true
        postsFrameChangedNotifications = true
        postsBoundsChangedNotifications = true
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.string, .fileContents, .html, .multipleTextSelection, .tabularText, .rtf])

        self.typingAttributes = [
            .font: font,
            .foregroundColor: textColor,
        ]

        textStorage.addAttributes(typingAttributes, range: documentRange)
        textStorage.delegate = storageDelegate

        layoutManager = setUpLayoutManager(lineHeightMultiplier: lineHeightMultiplier, wrapLines: wrapLines)
        storageDelegate.addDelegate(layoutManager)

        selectionManager = setUpSelectionManager()
        selectionManager.useSystemCursor = useSystemCursor

        layoutManager.attachments.setUpSelectionListener(for: selectionManager)

        _undoManager = CEUndoManager(textView: self)

        layoutManager.layoutLines()
        setUpDragGesture()
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public var documentRange: NSRange {
        NSRange(location: 0, length: textStorage.length)
    }

    // MARK: - Hit test

    /// Returns the responding view for a given point.
    /// - Parameter point: The point to find.
    /// - Returns: A view at the given point, if any.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        if visibleRect.contains(point) {
            return self
        } else {
            return super.hitTest(point)
        }
    }

    deinit {
        layoutManager = nil
        selectionManager = nil
        textStorage = nil
        NotificationCenter.default.removeObserver(self)
    }
}
