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
            comments: EditorTheme.Attribute(color: .systemGreen)
        )
    }
}
