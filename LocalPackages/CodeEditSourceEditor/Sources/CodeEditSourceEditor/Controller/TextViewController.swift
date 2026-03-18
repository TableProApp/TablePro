//
//  TextViewController.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/25/23.
//

import AppKit
import CodeEditTextView
import CodeEditLanguages
import SwiftUI
import Combine
import TextFormation

/// # TextViewController
/// 
/// A view controller class for managing a source editor. Uses ``CodeEditTextView/TextView`` for input and rendering,
/// tree-sitter for syntax highlighting, and TextFormation for live editing completions.
public class TextViewController: NSViewController {
    // swiftlint:disable:next line_length
    public static let cursorPositionUpdatedNotification: Notification.Name = .init("TextViewController.cursorPositionNotification")
    // swiftlint:disable:next line_length
    public static let scrollPositionDidUpdateNotification: Notification.Name = .init("TextViewController.scrollPositionDidUpdateNotification")

    // MARK: - Views and Child VCs

    weak var findViewController: FindViewController?

    internal(set) public var scrollView: NSScrollView!
    internal(set) public var textView: TextView!
    var gutterView: GutterView!
    var minimapView: MinimapView!

    /// The reformatting guide view
    var reformattingGuideView: ReformattingGuideView!

    /// Middleman between the text view to our invisible characters config, with knowledge of things like the
    ///  /// user's theme and indent option to help correctly draw invisible character placeholders.
    var invisibleCharactersCoordinator: InvisibleCharactersCoordinator

    var minimapXConstraint: NSLayoutConstraint?

    var _undoManager: CEUndoManager!
    var systemAppearance: NSAppearance.Name?

    var localEventMonitor: Any?
    var isPostingCursorNotification: Bool = false

    /// A default `NSParagraphStyle` with a set `lineHeight`
    lazy var paragraphStyle: NSMutableParagraphStyle = generateParagraphStyle()

    var suggestionTriggerModel = SuggestionTriggerCharacterModel()

    // MARK: - Public Variables

    /// Passthrough value for the `textView`s string
    public var text: String {
        get {
            textView.string
        }
        set {
            self.setText(newValue)
        }
    }

    /// The associated `CodeLanguage`
    public var language: CodeLanguage {
        didSet {
            highlighter?.setLanguage(language: language)
            setUpTextFormation()
        }
    }

    /// The configuration for the editor, when updated will automatically update the controller to reflect the new
    /// configuration.
    public var configuration: SourceEditorConfiguration {
        didSet {
            configuration.didSetOnController(controller: self, oldConfig: oldValue)
        }
    }

    /// The current cursors' positions ordered by the location of the cursor.
    internal(set) public var cursorPositions: [CursorPosition] = []

    /// The provided highlight provider.
    public var highlightProviders: [HighlightProviding]

    /// A delegate object that can respond to requests for completion items, filtering completion items, and triggering
    /// the suggestion window. See ``CodeSuggestionDelegate``.
    /// - Note: The ``TextViewController`` keeps only a `weak` reference to this object. To function properly, ensure a
    ///         strong reference to the delegate is kept *outside* of this variable.
    public weak var completionDelegate: CodeSuggestionDelegate?

    /// A delegate object that responds to requests for jump to definition actions. see ``JumpToDefinitionDelegate``.
    /// - Note: The ``TextViewController`` keeps only a `weak` reference to this object. To function properly, ensure a
    ///         strong reference to the delegate is kept *outside* of this variable.
    public var jumpToDefinitionDelegate: JumpToDefinitionDelegate? {
        get {
            jumpToDefinitionModel.delegate
        }
        set {
            jumpToDefinitionModel.delegate = newValue
        }
    }

    // MARK: - Config Helpers

    /// The font to use in the `textView`
    public var font: NSFont { configuration.appearance.font }

    /// The  ``EditorTheme`` used for highlighting.
    public var theme: EditorTheme { configuration.appearance.theme }

    /// The visual width of tab characters in the text view measured in number of spaces.
    public var tabWidth: Int { configuration.appearance.tabWidth }

    /// The behavior to use when the tab key is pressed.
    public var indentOption: IndentOption { configuration.behavior.indentOption }

    /// A multiplier for setting the line height. Defaults to `1.0`
    public var lineHeightMultiple: CGFloat { configuration.appearance.lineHeightMultiple }

    /// Whether lines wrap to the width of the editor
    public var wrapLines: Bool { configuration.appearance.wrapLines }

    /// The editorOverscroll to use for the textView over scroll
    ///
    /// Measured in a percentage of the view's total height, meaning a `0.3` value will result in overscroll
    /// of 1/3 of the view.
    public var editorOverscroll: CGFloat { configuration.layout.editorOverscroll }

    /// Whether the code editor should use the theme background color or be transparent
    public var useThemeBackground: Bool { configuration.appearance.useThemeBackground }

    /// Optional insets to offset the text view and find panel in the scroll view by.
    public var contentInsets: NSEdgeInsets? { configuration.layout.contentInsets }

    /// An additional amount to inset text by. Horizontal values are ignored.
    ///
    /// This value does not affect decorations like the find panel, but affects things that are relative to text, such
    /// as line numbers and of course the text itself.
    public var additionalTextInsets: NSEdgeInsets? { configuration.layout.additionalTextInsets }

    /// Whether or not text view is editable by user
    public var isEditable: Bool { configuration.behavior.isEditable }

    /// Whether or not text view is selectable by user
    public var isSelectable: Bool { configuration.behavior.isSelectable }

    /// A multiplier that determines the amount of space between characters. `1.0` indicates no space,
    /// `2.0` indicates one character of space between other characters.
    public var letterSpacing: Double { configuration.appearance.letterSpacing }

    /// The type of highlight to use when highlighting bracket pairs. Leave as `nil` to disable highlighting.
    public var bracketPairEmphasis: BracketPairEmphasis? { configuration.appearance.bracketPairEmphasis }

    /// The column at which to show the reformatting guide
    public var reformatAtColumn: Int { configuration.behavior.reformatAtColumn }

    /// If true, uses the system cursor on macOS 14 or greater.
    public var useSystemCursor: Bool { configuration.appearance.useSystemCursor }

    /// Toggle the visibility of the gutter view in the editor.
    public var showGutter: Bool { configuration.peripherals.showGutter }

    /// Toggle the visibility of the minimap view in the editor.
    public var showMinimap: Bool { configuration.peripherals.showMinimap }

    /// Toggle the visibility of the reformatting guide in the editor.
    public var showReformattingGuide: Bool { configuration.peripherals.showReformattingGuide }

    /// Configuration for drawing invisible characters.
    ///
    /// See ``InvisibleCharactersConfiguration`` for more details.
    public var invisibleCharactersConfiguration: InvisibleCharactersConfiguration {
        configuration.peripherals.invisibleCharactersConfiguration
    }

    /// Indicates characters that the user may not have meant to insert, such as a zero-width space: `(0x200D)` or a
    /// non-standard quote character: `“ (0x201C)`.
    public var warningCharacters: Set<UInt16> { configuration.peripherals.warningCharacters }

    // MARK: - Internal Variables

    var textCoordinators: [WeakCoordinator] = []

    var highlighter: Highlighter?

    /// The tree sitter client managed by the source editor.
    ///
    /// This will be `nil` if another highlighter provider is passed to the source editor.
    internal(set) public var treeSitterClient: TreeSitterClient? {
        didSet {
            jumpToDefinitionModel.treeSitterClient = treeSitterClient
        }
    }

    var foldProvider: LineFoldProvider

    /// Filters used when applying edits..
    var textFilters: [TextFormation.Filter] = []

    var jumpToDefinitionModel: JumpToDefinitionModel

    var cancellables = Set<AnyCancellable>()

    /// The trailing inset for the editor. Grows when line wrapping is disabled or when the minimap is shown.
    var textViewTrailingInset: CGFloat {
        // See https://github.com/CodeEditApp/CodeEditTextView/issues/66
        // wrapLines ? 1 : 48
        (minimapView?.isHidden ?? false) ? 0 : (minimapView?.frame.width ?? 0.0)
    }

    var textViewInsets: HorizontalEdgeInsets {
        HorizontalEdgeInsets(
            left: showGutter ? gutterView.frame.width : 0.0,
            right: textViewTrailingInset
        )
    }

    // MARK: Init

    public init(
        string: String,
        language: CodeLanguage,
        configuration: SourceEditorConfiguration,
        cursorPositions: [CursorPosition],
        highlightProviders: [HighlightProviding] = [TreeSitterClient()],
        foldProvider: LineFoldProvider? = nil,
        undoManager: CEUndoManager? = nil,
        coordinators: [TextViewCoordinator] = [],
        completionDelegate: CodeSuggestionDelegate? = nil,
        jumpToDefinitionDelegate: JumpToDefinitionDelegate? = nil
    ) {
        self.language = language
        self.configuration = configuration
        self.cursorPositions = cursorPositions
        self.highlightProviders = highlightProviders
        self.foldProvider = foldProvider ?? LineIndentationFoldProvider()
        self._undoManager = undoManager
        self.invisibleCharactersCoordinator = InvisibleCharactersCoordinator(configuration: configuration)
        self.completionDelegate = completionDelegate
        self.jumpToDefinitionModel = JumpToDefinitionModel(
            controller: nil,
            treeSitterClient: treeSitterClient,
            delegate: jumpToDefinitionDelegate
        )

        super.init(nibName: nil, bundle: nil)

        jumpToDefinitionModel.controller = self
        suggestionTriggerModel.controller = self

        if let idx = highlightProviders.firstIndex(where: { $0 is TreeSitterClient }),
           let client = highlightProviders[idx] as? TreeSitterClient {
            self.treeSitterClient = client
        }

        self.textView = SourceEditorTextView(
            string: string,
            font: font,
            textColor: theme.text.color,
            lineHeightMultiplier: lineHeightMultiple,
            wrapLines: wrapLines,
            isEditable: isEditable,
            isSelectable: isSelectable,
            letterSpacing: letterSpacing,
            useSystemCursor: useSystemCursor,
            delegate: self
        )

        textView.layoutManager.invisibleCharacterDelegate = invisibleCharactersCoordinator

        coordinators.forEach {
            $0.prepareCoordinator(controller: self)
        }
        self.textCoordinators = coordinators.map { WeakCoordinator($0) }

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Set the contents of the editor.
    /// - Parameter text: The new contents of the editor.
    public func setText(_ text: String) {
        self.textView.setText(text)
        self.setUpHighlighter()
        self.gutterView.setNeedsDisplay(self.gutterView.frame)
    }

    deinit {
        if let highlighter {
            textView.removeStorageDelegate(highlighter)
        }
        highlighter = nil
        highlightProviders.removeAll()
        textCoordinators.values().forEach {
            $0.destroy()
        }
        textCoordinators.removeAll()
        NotificationCenter.default.removeObserver(self)
        cancellables.forEach { $0.cancel() }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
        }
        localEventMonitor = nil
    }
}
