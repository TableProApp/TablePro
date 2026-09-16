//
//  TextView+TextFormation.swift
//  TableProEditorKit
//
//  Created by Khan Winter on 10/14/23.
//

import Foundation
import TableProTextEngine
import TextFormation
import TextStory

extension TextView: @retroactive TextStoring {}
extension TextView: @retroactive TextInterface {
    public var selectedRange: NSRange {
        get {
            selectionManager
                .textSelections
                .min(by: { $0.range.lowerBound < $1.range.lowerBound })?
                .range ?? .zero
        }
        set {
            selectionManager.setSelectedRange(newValue)
        }
    }

    public var length: Int {
        textStorage.length
    }

    public func substring(from range: NSRange) -> String? {
        textStorage.substring(from: range)
    }

    /// Applies the mutation to the text view.
    ///
    /// If the mutation is empty it will be ignored.
    ///
    /// - Parameter mutation: The mutation to apply.
    public func applyMutation(_ mutation: TextMutation) {
        guard !mutation.isEmpty else { return }
        editorUndoManager?.registerMutation(mutation)
        textStorage.replaceCharacters(in: mutation.range, with: mutation.string)
        selectionManager.didReplaceCharacters(
            in: mutation.range,
            replacementLength: (mutation.string as NSString).length
        )
        layoutManager.invalidateLayoutForRange(mutation.range)
    }
}
