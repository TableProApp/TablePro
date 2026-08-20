//
//  PasteHighlightCancelTests.swift
//  TableProTests
//
//  A cancelled tree-sitter edit used to invalidate the range as it was BEFORE the edit. That range
//  is empty for an insertion at a caret, and `HighlightProviderState.invalidate(_:)` returns without
//  doing anything for an empty set, so the pasted text kept the default typing attributes it was
//  inserted with and was never queried again. It stayed the wrong colour for the rest of the
//  session while every token around it kept its highlighting.
//
//  These tests drive a real `TextViewController` and a stub `HighlightProviding` whose failure mode
//  is switchable, because the shipping tree-sitter client cannot be made to cancel on demand.
//

import AppKit
import CodeEditLanguages
@testable import CodeEditSourceEditor
import CodeEditTextView
import Foundation
import Rearrange
import Testing

@MainActor
private final class SwitchableHighlightProvider: HighlightProviding {
    enum Mode {
        case healthy
        case editCancelled
    }

    var mode: Mode = .healthy

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {}

    func applyEdit(
        textView: TextView,
        range: NSRange,
        delta: Int,
        completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        switch mode {
        case .editCancelled:
            completion(.failure(HighlightProvidingError.operationCancelled))
        case .healthy:
            completion(.success(IndexSet()))
        }
    }

    /// Colours every run of digits, so a test can ask whether a pasted number was repainted without
    /// depending on the SQL grammar.
    func queryHighlightsFor(
        textView: TextView,
        range: NSRange,
        completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        let text = textView.string as NSString
        var highlights: [HighlightRange] = []
        var index = range.location
        while index < min(range.max, text.length) {
            guard Self.isDigit(text.character(at: index)) else {
                index += 1
                continue
            }
            var end = index
            while end < min(range.max, text.length), Self.isDigit(text.character(at: end)) {
                end += 1
            }
            highlights.append(HighlightRange(range: NSRange(location: index, length: end - index), capture: .number))
            index = end
        }
        completion(.success(highlights))
    }

    private static func isDigit(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.decimalDigits.contains(scalar)
    }
}

@MainActor
@Suite("Highlighting survives a cancelled edit", .serialized)
struct PasteHighlightCancelTests {
    private static let defaultText = NSColor.systemPurple
    private static let numbers = NSColor.systemYellow
    private static let document = "select * from t where id = 1100000002488697;\nselect 1;\n"
    private static let originalToken = "1100000002488697"
    private static let sameLengthToken = "1100000002488698"
    private static let frame = NSRect(x: 0, y: 0, width: 900, height: 600)

    // MARK: - The range arithmetic, with no editor involved

    @Test("An insertion at a caret yields a non-empty edited set")
    func caretInsertionIsNotEmpty() {
        let set = HighlightProviderState.editedIndices(range: NSRange(location: 10, length: 0), delta: 3)
        #expect(!set.isEmpty)
        #expect(set.contains(integersIn: 10..<13))
    }

    @Test("A deletion yields a non-empty edited set covering what was removed")
    func deletionIsNotEmpty() {
        let set = HighlightProviderState.editedIndices(range: NSRange(location: 10, length: 5), delta: -5)
        #expect(!set.isEmpty)
        #expect(set.contains(integersIn: 10..<15))
    }

    @Test("A same-length replacement yields exactly the replaced span")
    func sameLengthReplacement() {
        let set = HighlightProviderState.editedIndices(range: NSRange(location: 10, length: 4), delta: 0)
        #expect(set == IndexSet(integersIn: 10..<14))
    }

    @Test("A replacement that grows covers both the old and the new span")
    func growingReplacement() {
        let set = HighlightProviderState.editedIndices(range: NSRange(location: 10, length: 2), delta: 3)
        #expect(set == IndexSet(integersIn: 10..<15))
    }

    // MARK: - The same thing through a real controller

    @Test("A cancelled edit still repaints text inserted at a caret")
    func cancelledEditRepaintsCaretInsertion() async throws {
        let provider = SwitchableHighlightProvider()
        let controller = makeController(provider)
        await settle(controller)

        let token = (controller.textView.string as NSString).range(of: Self.originalToken)
        #expect(color(at: token.location, in: controller) == Self.numbers)

        provider.mode = .editCancelled
        let caret = token.max
        controller.textView.selectionManager.setSelectedRange(NSRange(location: caret, length: 0))
        controller.textView.insertText("999")
        await settle(controller)

        #expect(
            color(at: caret, in: controller) == Self.numbers,
            "Text inserted at a caret must be repainted even when the edit was cancelled"
        )
    }

    @Test("A cancelled edit still repaints a replaced selection")
    func cancelledEditRepaintsSelectionReplacement() async throws {
        let provider = SwitchableHighlightProvider()
        let controller = makeController(provider)
        await settle(controller)

        let token = (controller.textView.string as NSString).range(of: Self.originalToken)
        #expect(color(at: token.location, in: controller) == Self.numbers)

        provider.mode = .editCancelled
        controller.textView.selectionManager.setSelectedRange(token)
        controller.textView.insertText(Self.sameLengthToken)
        await settle(controller)

        #expect(color(at: token.location, in: controller) == Self.numbers)
    }

    @Test("A healthy edit repaints, so the stub itself is not what makes the test pass")
    func healthyEditRepaints() async throws {
        let provider = SwitchableHighlightProvider()
        let controller = makeController(provider)
        await settle(controller)

        let token = (controller.textView.string as NSString).range(of: Self.originalToken)
        controller.textView.selectionManager.setSelectedRange(token)
        controller.textView.insertText(Self.sameLengthToken)
        await settle(controller)

        #expect(color(at: token.location, in: controller) == Self.numbers)
    }

    // MARK: - Helpers

    private func makeController(_ provider: SwitchableHighlightProvider) -> TextViewController {
        let theme = EditorTheme(
            text: EditorTheme.Attribute(color: Self.defaultText),
            insertionPoint: Self.defaultText,
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
            numbers: EditorTheme.Attribute(color: Self.numbers),
            strings: EditorTheme.Attribute(color: .systemRed),
            characters: EditorTheme.Attribute(color: .systemRed),
            comments: EditorTheme.Attribute(color: .systemGreen)
        )
        let controller = TextViewController(
            string: Self.document,
            language: .sql,
            configuration: SourceEditorConfiguration(
                appearance: .init(
                    theme: theme,
                    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                    lineHeightMultiple: 1.0,
                    wrapLines: false,
                    tabWidth: 4
                )
            ),
            cursorPositions: [],
            highlightProviders: [provider]
        )
        controller.loadView()
        controller.view.frame = Self.frame
        controller.view.layoutSubtreeIfNeeded()
        controller.textView.layoutManager.layoutLines(in: Self.frame)
        return controller
    }

    private func color(at location: Int, in controller: TextViewController) -> NSColor? {
        guard let storage = controller.textView.textStorage, location < storage.length else { return nil }
        return storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    private func settle(_ controller: TextViewController) async {
        for _ in 0..<8 {
            controller.textView.layoutManager.layoutLines(in: Self.frame)
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
    }
}
