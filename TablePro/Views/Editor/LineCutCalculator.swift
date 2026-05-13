//
//  LineCutCalculator.swift
//  TablePro
//

import Foundation

/// Pure logic for resolving a Cmd+X cut operation on the SQL editor's text
/// view. When a selection exists the selection is the cut target; with no
/// selection the entire current line (including its trailing newline, if any)
/// is the cut target — matching the convention used by VS Code, Sublime,
/// JetBrains IDEs, and Xcode's source editor.
enum LineCutCalculator {
    struct Result: Equatable {
        let rangeToDelete: NSRange
        let clipboardText: String
    }

    static func calculate(text: String, selection: NSRange) -> Result? {
        let nsText = text as NSString
        guard nsText.length > 0 else { return nil }
        guard selection.location >= 0,
              selection.location <= nsText.length,
              selection.location + selection.length <= nsText.length else {
            return nil
        }

        if selection.length > 0 {
            return Result(
                rangeToDelete: selection,
                clipboardText: nsText.substring(with: selection)
            )
        }

        let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        guard lineRange.length > 0 else { return nil }
        return Result(
            rangeToDelete: lineRange,
            clipboardText: nsText.substring(with: lineRange)
        )
    }
}
