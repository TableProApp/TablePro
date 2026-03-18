//
//  DeleteWhitespaceFilter.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 1/28/23.
//

import Foundation
import CodeEditTextView
import TextFormation
import TextStory

/// Filter for quickly deleting indent whitespace
///
/// Will only delete whitespace when it's on the leading side of the line. Will delete back to the nearest tab column.
/// Eg:
/// ```text
/// (| = column delimiter, _ = space, * = cursor)
///
/// ____|___*   <- delete
/// ----*       <- final
/// ```
/// Will also move the cursor to the trailing side of the whitespace if it is not there already:
/// ```text
/// ____|_*___|__   <- delete
/// ____|____*      <- final
/// ```
struct DeleteWhitespaceFilter: Filter {
    let indentOption: IndentOption

    func processMutation(
        _ mutation: TextMutation,
        in interface: TextInterface,
        with providers: WhitespaceProviders
    ) -> FilterAction {
        guard mutation.delta < 0
                && mutation.string == ""
                && mutation.range.length == 1
                && indentOption != .tab else {
            return .none
        }

        let lineRange = interface.lineRange(containing: mutation.range.location)
        guard let leadingWhitespace = interface.leadingRange(in: lineRange, within: .whitespacesWithoutNewlines),
              leadingWhitespace.contains(mutation.range.location) else {
            return .none
        }

        // Move to right of the whitespace and delete to the left-most tab column
        let indentLength = indentOption.stringValue.count
        var numberOfExtraSpaces = leadingWhitespace.length % indentLength
        if numberOfExtraSpaces == 0 {
            numberOfExtraSpaces = indentLength
        }

        interface.applyMutation(
            TextMutation(
                delete: NSRange(location: leadingWhitespace.max - numberOfExtraSpaces, length: numberOfExtraSpaces),
                limit: mutation.limit
            )
        )

        return .discard
    }
}
