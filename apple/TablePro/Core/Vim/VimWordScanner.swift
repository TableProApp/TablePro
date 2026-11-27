import Foundation

// Word and WORD scans for Vim's motions. They step by composed character sequence and class each one by its first
// scalar, so a variation selector or a combining mark after a symbol never splits it into two words.
enum VimWordScanner {
    enum CharacterClass {
        case word, punctuation, whitespace
    }

    static func characterClass(lead: unichar, trail: unichar?) -> CharacterClass {
        if lead == 0x20 || lead == 0x09 || lead == 0x0A || lead == 0x0D { return .whitespace }
        if lead == 0x5F { return .word }
        var value = UInt32(lead)
        if UTF16.isLeadSurrogate(lead), let trail, UTF16.isTrailSurrogate(trail) {
            value = 0x10000 + ((UInt32(lead) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(value) else { return .punctuation }
        return CharacterSet.alphanumerics.contains(scalar) ? .word : .punctuation
    }

    static func characterClass(at offset: Int, in text: NSString) -> CharacterClass {
        let base = characterStart(at: offset, in: text)
        let lead = text.character(at: base)
        return characterClass(lead: lead, trail: base + 1 < text.length ? text.character(at: base + 1) : nil)
    }

    static func wordBoundary(forward: Bool, from offset: Int, in text: NSString) -> Int {
        scanBoundary(forward: forward, from: offset, in: text) { characterClass(at: $0, in: text) }
    }

    static func bigWordBoundary(forward: Bool, from offset: Int, in text: NSString) -> Int {
        scanBoundary(forward: forward, from: offset, in: text) { bigClass(at: $0, in: text) }
    }

    static func wordEnd(from offset: Int, in text: NSString) -> Int {
        scanEnd(from: offset, in: text) { characterClass(at: $0, in: text) }
    }

    static func bigWordEnd(from offset: Int, in text: NSString) -> Int {
        scanEnd(from: offset, in: text) { bigClass(at: $0, in: text) }
    }

    static func wordEndBackward(from offset: Int, in text: NSString) -> Int {
        scanEndBackward(from: offset, in: text) { characterClass(at: $0, in: text) }
    }

    static func bigWordEndBackward(from offset: Int, in text: NSString) -> Int {
        scanEndBackward(from: offset, in: text) { bigClass(at: $0, in: text) }
    }

    // MARK: - Scans

    private static func bigClass(at offset: Int, in text: NSString) -> CharacterClass {
        characterClass(at: offset, in: text) == .whitespace ? .whitespace : .word
    }

    private static func characterStart(at offset: Int, in text: NSString) -> Int {
        // Below U+0300 a unit after another such unit starts its own character, which skips the lookup for ASCII.
        if text.character(at: offset) < 0x300, offset == 0 || text.character(at: offset - 1) < 0x300 {
            return offset
        }
        return text.rangeOfComposedCharacterSequence(at: offset).location
    }

    private static func next(_ offset: Int, in text: NSString) -> Int {
        NSMaxRange(text.rangeOfComposedCharacterSequence(at: offset))
    }

    private static func previous(_ offset: Int, in text: NSString) -> Int {
        characterStart(at: offset - 1, in: text)
    }

    private static func scanBoundary(
        forward: Bool,
        from offset: Int,
        in text: NSString,
        classOf: (Int) -> CharacterClass
    ) -> Int {
        guard text.length > 0 else { return 0 }
        if forward {
            var pos = characterStart(at: min(max(0, offset), text.length - 1), in: text)
            let startClass = classOf(pos)
            if startClass != .whitespace {
                while pos < text.length && classOf(pos) == startClass { pos = next(pos, in: text) }
            }
            while pos < text.length && classOf(pos) == .whitespace { pos = next(pos, in: text) }
            return min(pos, text.length)
        }
        var pos = min(max(0, offset), text.length)
        if pos > 0 { pos = previous(pos, in: text) }
        while pos > 0 && classOf(pos) == .whitespace { pos = previous(pos, in: text) }
        let cls = classOf(pos)
        while pos > 0 && classOf(previous(pos, in: text)) == cls { pos = previous(pos, in: text) }
        return pos
    }

    // The start of the last character of the next word. An offset below 0 starts at the first character, so the
    // word under the caret counts.
    private static func scanEnd(from offset: Int, in text: NSString, classOf: (Int) -> CharacterClass) -> Int {
        guard text.length > 0 else { return 0 }
        let last = characterStart(at: text.length - 1, in: text)
        var pos = offset < 0 ? 0 : min(next(min(offset, text.length - 1), in: text), last)
        while pos < text.length && classOf(pos) == .whitespace { pos = next(pos, in: text) }
        guard pos < text.length else { return last }
        let cls = classOf(pos)
        while next(pos, in: text) < text.length && classOf(next(pos, in: text)) == cls { pos = next(pos, in: text) }
        return pos
    }

    private static func scanEndBackward(from offset: Int, in text: NSString, classOf: (Int) -> CharacterClass) -> Int {
        guard text.length > 0 else { return 0 }
        var pos = characterStart(at: min(max(0, offset), text.length - 1), in: text)
        if pos > 0 { pos = previous(pos, in: text) }
        if classOf(pos) == .whitespace {
            while pos > 0 && classOf(pos) == .whitespace { pos = previous(pos, in: text) }
            return pos
        }
        let cls = classOf(pos)
        while pos > 0 && classOf(previous(pos, in: text)) == cls { pos = previous(pos, in: text) }
        guard pos > 0 else { return 0 }
        pos = previous(pos, in: text)
        while pos > 0 && classOf(pos) == .whitespace { pos = previous(pos, in: text) }
        return pos
    }
}
