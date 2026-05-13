//
//  MentionDetector.swift
//  TablePro
//

import Foundation

struct MentionMatch: Equatable, Sendable {
    let range: NSRange
    let query: String
}

enum MentionDetector {
    private static let triggerScalar: Unicode.Scalar = "@"

    static func detect(in text: String, caret: Int) -> MentionMatch? {
        guard caret >= 0 else { return nil }
        let utf16Length = text.utf16.count
        guard caret <= utf16Length else { return nil }

        let caretIndex = String.Index(utf16Offset: caret, in: text)
        let scalars = text.unicodeScalars
        let scalarStart = scalars.startIndex
        let scalarCaret = caretIndex.samePosition(in: scalars) ?? caretIndex
        var cursor = scalarCaret

        while cursor > scalarStart {
            let previous = scalars.index(before: cursor)
            let scalar = scalars[previous]
            if scalar == triggerScalar {
                guard isBoundary(before: previous, in: scalars) else { return nil }
                let triggerOffset = previous.utf16Offset(in: text)
                let queryStart = scalars.index(after: previous)
                let query = String(scalars[queryStart ..< scalarCaret])
                return MentionMatch(
                    range: NSRange(location: triggerOffset, length: caret - triggerOffset),
                    query: query
                )
            }
            if !isQueryCharacter(scalar) { return nil }
            cursor = previous
        }
        return nil
    }

    private static func isQueryCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        return CharacterSet.letters.contains(scalar)
    }

    private static func isBoundary(before index: String.UnicodeScalarView.Index,
                                   in scalars: String.UnicodeScalarView) -> Bool {
        guard index > scalars.startIndex else { return true }
        let scalar = scalars[scalars.index(before: index)]
        return !isQueryCharacter(scalar)
    }
}
