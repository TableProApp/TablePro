//
//  TextView+Delete.swift
//  TableProTextEngine
//
//  Created by Khan Winter on 8/24/23.
//

import AppKit

extension TextView {
    override open func deleteBackward(_ sender: Any?) {
        delete(direction: .backward, destination: .character)
    }

    override open func deleteBackwardByDecomposingPreviousCharacter(_ sender: Any?) {
        delete(direction: .backward, destination: .character, decomposeCharacters: true)
    }

    override open func deleteForward(_ sender: Any?) {
        delete(direction: .forward, destination: .character)
    }

    override open func deleteWordBackward(_ sender: Any?) {
        delete(direction: .backward, destination: .word)
    }

    override open func deleteWordForward(_ sender: Any?) {
        delete(direction: .forward, destination: .word)
    }

    override open func deleteToBeginningOfLine(_ sender: Any?) {
        delete(direction: .backward, destination: .line)
    }

    override open func deleteToEndOfLine(_ sender: Any?) {
        delete(direction: .forward, destination: .line)
    }

    override open func deleteToBeginningOfParagraph(_ sender: Any?) {
        delete(direction: .backward, destination: .line)
    }

    override open func deleteToEndOfParagraph(_ sender: Any?) {
        delete(direction: .forward, destination: .line)
    }

    private func delete(
        direction: TextSelectionManager.Direction,
        destination: TextSelectionManager.Destination,
        decomposeCharacters: Bool = false
    ) {
        // A selectable read-only view still routes key equivalents here. `replaceCharacters` refuses the edit, but
        // only after this method has already widened the selection and filled the kill ring.
        guard isEditable else { return }

        /// Extend each selection by a distance specified by `destination`, then update both storage and the selection.
        for textSelection in selectionManager.textSelections {
            guard textSelection.range.isEmpty else { continue }
            let extendedRange = selectionManager.rangeOfSelection(
                from: textSelection.range.location,
                direction: direction,
                destination: destination
            )
            guard extendedRange.location >= 0 else { continue }
            textSelection.range.formUnion(extendedRange)
        }
        selectionManager.textSelections.sort(by: { $0.range.location < $1.range.location })
        KillRing.shared.kill(
            strings: selectionManager.textSelections.map(\.range).compactMap({ textStorage.substring(from: $0) })
        )
        replaceCharacters(in: selectionManager.textSelections.map(\.range), with: "")
        unmarkTextIfNeeded()
    }
}
