import Foundation

nonisolated enum EditorTabNameNormalizer {
    static let maximumLength = 100

    // Nil means nothing visible is left, so the tab goes back to its automatic name.
    static func normalize(_ text: String) -> String? {
        let oneLine = trimmed(collapsingBreaks(in: text))
        let name = trimmed(String(oneLine.prefix(maximumLength)))
        guard name.unicodeScalars.contains(where: { !isBlank($0) }) else { return nil }
        return name
    }

    // A tab label is one line, so a pasted line break or tab reads as a space.
    private static func collapsingBreaks(in text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var inBreak = false
        for scalar in text.unicodeScalars {
            if isBreak(scalar) {
                if !inBreak { scalars.append(" ") }
                inBreak = true
            } else {
                scalars.append(scalar)
                inBreak = false
            }
        }
        return String(scalars)
    }

    private static func isBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }

    // A zero-width joiner or a byte order mark alone draws a blank tab; inside a name, a joiner holds an emoji together.
    private static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar.properties.generalCategory == .format
    }

    // By character, so a combining mark is never split from the letter it sits on.
    private static func trimmed(_ text: String) -> String {
        guard let first = text.firstIndex(where: { !$0.isWhitespace }),
              let last = text.lastIndex(where: { !$0.isWhitespace })
        else { return "" }
        return String(text[first...last])
    }
}
