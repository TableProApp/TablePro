import Foundation

public enum StatementBlank {
    private static let interlinearAnnotations: ClosedRange<UInt32> = 0xFFF9...0xFFFB
    private static let asciiDelete: UInt32 = 0x7F
    private static let asciiSpace: UInt32 = 0x20

    public static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        guard !scalar.isASCII else { return scalar.value <= asciiSpace || scalar.value == asciiDelete }
        let properties = scalar.properties
        guard !properties.isAlphabetic else { return false }
        return properties.isWhitespace
            || properties.generalCategory == .control
            || properties.isDefaultIgnorableCodePoint
            || interlinearAnnotations.contains(scalar.value)
    }

    public static func isBlank(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { isBlank($0) }
    }

    public static func hasContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { !isBlank($0) }
    }

    public static func blankLength(in text: NSString, at offset: Int) -> Int {
        guard let scalar = scalar(in: text, at: offset), isBlank(scalar) else { return 0 }
        return scalar.utf16.count
    }

    public static func trimming(_ text: String) -> String {
        String(trimming(text[...]))
    }

    public static func trimming(_ text: Substring) -> Substring {
        let leading = trimmingLeading(text)
        guard let last = leading.lastIndex(where: { !isBlank($0) }) else { return leading[leading.endIndex...] }
        return leading[...last]
    }

    public static func trimmingLeading(_ text: Substring) -> Substring {
        text.drop { isBlank($0) }
    }

    public static func contentRange(of text: String) -> NSRange {
        let content = trimming(text[...])
        return NSRange(content.startIndex..<content.endIndex, in: text)
    }

    private static func scalar(in text: NSString, at offset: Int) -> Unicode.Scalar? {
        guard offset >= 0, offset < text.length else { return nil }
        let unit = text.character(at: offset)
        guard UTF16.isLeadSurrogate(unit) else { return Unicode.Scalar(unit) }
        guard offset + 1 < text.length else { return nil }
        let trail = text.character(at: offset + 1)
        guard UTF16.isTrailSurrogate(trail) else { return nil }
        return Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00))
    }
}
