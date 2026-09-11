//
//  SQLEditorCoordinator+InvisibleCharacters.swift
//  TablePro
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import TableProPluginKit

extension SQLEditorCoordinator {
    func performRemoveInvisibleCharacters() {
        guard let controller, let textView = controller.textView, textView.isEditable else { return }
        let string = textView.string
        let scope = FormatScopeResolver.resolve(fullText: string, selectedRange: textView.selectedRange())
        let replacements = InvisibleCharacterRemover.replacements(
            in: string as NSString,
            scope: scope.range,
            skippingLiteralsAndComments: !scope.isSelection,
            dialect: SqlDialect.from(databaseTypeId: (databaseType ?? .mysql).rawValue),
            lineEnding: textView.layoutManager.detectedLineEnding.rawValue
        )
        guard !replacements.isEmpty else { return }

        controller.applyUnfilteredReplacements(replacements)
        controller.setCursorPositions(
            [CursorPosition(range: selection(after: replacements, in: scope))],
            scrollToVisible: true
        )
    }

    private func selection(after replacements: [TextReplacement], in scope: FormatScopeResolver.Scope) -> NSRange {
        guard scope.isSelection else {
            let caret = InvisibleCharacterRemover.mappedOffset(scope.cursorOffset ?? 0, through: replacements)
            return NSRange(location: caret, length: 0)
        }
        let end = InvisibleCharacterRemover.mappedOffset(NSMaxRange(scope.range), through: replacements)
        return NSRange(location: scope.range.location, length: max(0, end - scope.range.location))
    }
}
