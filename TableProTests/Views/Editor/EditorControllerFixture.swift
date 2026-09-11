//
//  EditorControllerFixture.swift
//  TableProTests
//
//  A real, laid-out TextViewController for tests that need the editor's actual
//  AppKit behaviour rather than a stand-in.
//

import AppKit
import CodeEditLanguages
@testable import CodeEditSourceEditor
import CodeEditTextView

@MainActor
internal enum EditorControllerFixture {
    internal static func make(
        string: String = "",
        coordinators: [TextViewCoordinator] = []
    ) -> TextViewController {
        let controller = TextViewController(
            string: string,
            language: .default,
            configuration: configuration,
            cursorPositions: [],
            highlightProviders: [],
            coordinators: coordinators
        )
        controller.loadView()
        controller.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 1_000)
        controller.view.layoutSubtreeIfNeeded()
        return controller
    }

    internal static func makeFocusedInWindow(string: String) -> (NSWindow, TextViewController) {
        let controller = make(string: string)
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

    internal static func beginComposition(_ markedText: String, in textView: TextView) {
        textView.setMarkedText(
            markedText,
            selectedRange: NSRange(location: (markedText as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    internal static func emptyComposition(in textView: TextView) {
        textView.setMarkedText(
            "",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    internal static func keyDown(
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

    private static var configuration: SourceEditorConfiguration {
        SourceEditorConfiguration(
            appearance: .init(
                theme: theme,
                font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                lineHeightMultiple: 1.0,
                wrapLines: false,
                tabWidth: 4
            )
        )
    }

    private static var theme: EditorTheme {
        EditorTheme(
            text: EditorTheme.Attribute(color: .textColor),
            insertionPoint: .textColor,
            invisibles: EditorTheme.Attribute(color: .gray),
            background: .textBackgroundColor,
            lineHighlight: .selectedTextBackgroundColor,
            selection: .selectedTextColor,
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
}
