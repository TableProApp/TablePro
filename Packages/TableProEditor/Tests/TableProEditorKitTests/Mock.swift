import AppKit
import Foundation
@testable import TableProEditorKit
import TableProGrammars
import TableProTextEngine

class MockHighlightProvider: HighlightProviding {
    var onSetUp: (CodeLanguage) -> Void
    var onApplyEdit: (_ textView: TextView, _ range: NSRange, _ delta: Int) -> Result<IndexSet, any Error>
    var onQueryHighlightsFor: (_ textView: TextView, _ range: NSRange) -> Result<[HighlightRange], any Error>

    init(
        onSetUp: @escaping (CodeLanguage) -> Void,
        onApplyEdit: @escaping (_: TextView, _: NSRange, _: Int) -> Result<IndexSet, any Error>,
        onQueryHighlightsFor: @escaping (_: TextView, _: NSRange) -> Result<[HighlightRange], any Error>
    ) {
        self.onSetUp = onSetUp
        self.onApplyEdit = onApplyEdit
        self.onQueryHighlightsFor = onQueryHighlightsFor
    }

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        self.onSetUp(codeLanguage)
    }

    func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, any Error>) -> Void
    ) {
        completion(self.onApplyEdit(textView, range, delta))
    }

    func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], any Error>) -> Void
    ) {
        completion(self.onQueryHighlightsFor(textView, range))
    }
}

enum Mock {
    class Delegate: TextViewDelegate { }

    static func config() -> SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: theme(),
                font: .monospacedSystemFont(ofSize: 11, weight: .medium),
                lineHeightMultiple: 1.0,
                wrapLines: true,
                tabWidth: 4
            )
        )
    }

    static func textViewController(theme: EditorTheme) -> TextViewController {
        TextViewController(
            string: "",
            language: .sql,
            configuration: config(),
            cursorPositions: [],
            highlightProviders: [TreeSitterClient()]
        )
    }

    /// A controller whose view is loaded and laid out, for tests that need the editor's real AppKit
    /// behaviour rather than a stand-in.
    @MainActor
    static func loadedTextViewController(
        string: String = "",
        wrapLines: Bool = false,
        coordinators: [TextViewCoordinator] = []
    ) -> TextViewController {
        let controller = TextViewController(
            string: string,
            language: .default,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: theme(),
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    lineHeightMultiple: 1.0,
                    wrapLines: wrapLines,
                    tabWidth: 4
                )
            ),
            cursorPositions: [],
            highlightProviders: [],
            coordinators: coordinators
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    @MainActor
    static func focusedTextViewController(string: String) -> (NSWindow, TextViewController) {
        let controller = loadedTextViewController(string: string)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 1_000),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        controller.view.layoutSubtreeIfNeeded()
        _ = window.makeFirstResponder(controller.textView)
        let end = (string as NSString).length
        controller.setCursorPositions([CursorPosition(range: NSRange(location: end, length: 0))])
        return (window, controller)
    }

    @MainActor
    static func beginComposition(_ markedText: String, in textView: TextView) {
        textView.setMarkedText(
            markedText,
            selectedRange: NSRange(location: (markedText as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    @MainActor
    static func emptyComposition(in textView: TextView) {
        textView.setMarkedText(
            "",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    static func keyDown(
        keyCode: Int,
        characters: String,
        modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow?
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )
    }

    @MainActor
    static func windowedTextViewController(theme: EditorTheme) -> (NSWindow, TextViewController) {
        let controller = textViewController(theme: theme)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        return (window, controller)
    }

    static func theme() -> EditorTheme {
        EditorTheme(
            text: EditorTheme.Attribute(color: .textColor),
            insertionPoint: .textColor.usingColorSpace(.deviceRGB) ?? .black,
            invisibles: EditorTheme.Attribute(color: .gray),
            background: .textBackgroundColor.usingColorSpace(.deviceRGB) ?? .black,
            lineHighlight: .highlightColor.usingColorSpace(.deviceRGB) ?? .black,
            selection: .selectedTextColor.usingColorSpace(.deviceRGB) ?? .black,
            keywords: EditorTheme.Attribute(color: .systemPink),
            commands: EditorTheme.Attribute(color: .systemBlue),
            types: EditorTheme.Attribute(color: .systemMint),
            attributes: EditorTheme.Attribute(color: .systemTeal),
            variables: EditorTheme.Attribute(color: .systemCyan),
            values: EditorTheme.Attribute(color: .systemOrange),
            numbers: EditorTheme.Attribute(color: .systemYellow),
            strings: EditorTheme.Attribute(color: .systemRed),
            characters: EditorTheme.Attribute(color: .systemRed),
            comments: EditorTheme.Attribute(color: .systemGreen),
            operators: EditorTheme.Attribute(color: .systemBrown),
            functions: EditorTheme.Attribute(color: .systemIndigo)
        )
    }

    static func textView() -> TextView {
        TextView(
            string: "func testSwiftFunc() -> Int {\n\tprint(\"\")\n}",
            font: .monospacedSystemFont(ofSize: 12, weight: .regular),
            textColor: .labelColor,
            lineHeightMultiplier: 1.0,
            wrapLines: true,
            isEditable: true,
            isSelectable: true,
            letterSpacing: 1.0,
            delegate: Delegate()
        )
    }

    static func scrollingTextView() -> (NSScrollView, TextView) {
        let scrollView = NSScrollView(frame: .init(x: 0, y: 0, width: 250, height: 250))
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        let textView = textView()
        scrollView.documentView = textView
        scrollView.layoutSubtreeIfNeeded()
        textView.layout()
        return (scrollView, textView)
    }

    static func treeSitterClient(forceSync: Bool = false) -> TreeSitterClient {
        let client = TreeSitterClient()
        client.forceSyncOperation = forceSync
        return client
    }

    @MainActor
    static func highlighter(
        textView: TextView,
        highlightProviders: [HighlightProviding],
        attributeProvider: ThemeAttributesProviding,
        language: CodeLanguage = .default
    ) -> Highlighter {
        let highlighter = Highlighter(
            textView: textView,
            providers: highlightProviders,
            attributeProvider: attributeProvider,
            language: language
        )
        // `TextViewController.setUpHighlighter` does this, and it is the only route an edit takes to a highlighter.
        // Leaving it to each call site is what left two max-length tests asserting against a highlighter nothing
        // ever spoke to.
        textView.addStorageDelegate(highlighter)
        return highlighter
    }

    static func highlightProvider(
        onSetUp: @escaping (CodeLanguage) -> Void,
        onApplyEdit: @escaping (TextView, NSRange, Int) -> Result<IndexSet, any Error>,
        onQueryHighlightsFor: @escaping (TextView, NSRange) -> Result<[HighlightRange], any Error>
    ) -> MockHighlightProvider {
        MockHighlightProvider(onSetUp: onSetUp, onApplyEdit: onApplyEdit, onQueryHighlightsFor: onQueryHighlightsFor)
    }
}
