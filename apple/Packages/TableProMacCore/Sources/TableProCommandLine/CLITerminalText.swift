import Darwin
import Foundation

enum CLITerminalText {
    // A Swift process runs in the C locale, where wcwidth answers -1 for anything past ASCII.
    nonisolated(unsafe) private static let utf8Locale = newlocale(LC_CTYPE_MASK, "UTF-8", nil)

    static func message(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: escapesInMessage) else { return text }
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if escapesInMessage(scalar) {
                escaped += hex(scalar)
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    static func hex(_ scalar: Unicode.Scalar) -> String {
        String(format: "\\x%02X", scalar.value)
    }

    static func width(of text: String) -> Int {
        guard !text.utf8.allSatisfy({ $0 < 0x80 }) else { return text.utf8.count }
        let previous = uselocale(utf8Locale)
        defer { uselocale(previous) }
        return text.reduce(0) { $0 + width(of: $1) }
    }

    // Terminals draw a grapheme cluster as one glyph, so a joined emoji or a base with combining marks
    // takes the width of its widest scalar, not the sum. wcwidth calls VS16 sequences and flags
    // narrow, but terminals draw them two cells wide.
    private static func width(of character: Character) -> Int {
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.value == 0xFE0F }) {
            return 2
        }
        if let first = scalars.first, (0x1F1E6...0x1F1FF).contains(first.value) {
            return 2
        }
        let widest = scalars.map { Int(wcwidth(wchar_t(bitPattern: $0.value))) }.max() ?? 0
        return widest < 0 ? 1 : widest
    }

    private static func escapesInMessage(_ scalar: Unicode.Scalar) -> Bool {
        scalar != "\n" && scalar != "\t" && isControl(scalar)
    }
}
