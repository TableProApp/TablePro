//
//  SpecialCharacter.swift
//  CodeEditTextView
//

import Foundation

public enum SpecialCharacter: Equatable, Sendable {
    case marker(label: String)
    case blankSpace
}

public struct ClassifiedSpecialCharacter: Equatable, Sendable {
    public let character: SpecialCharacter
    public let range: NSRange
    public let scalar: Unicode.Scalar
}

public extension ClassifiedSpecialCharacter {
    var name: String {
        SpecialCharacter.controlName(for: scalar.value)
            ?? scalar.properties.name?.lowercased()
            ?? String(format: "U+%04X", scalar.value)
    }
}

public extension SpecialCharacter {
    static func classify(in string: NSString, at index: Int) -> ClassifiedSpecialCharacter? {
        guard index >= 0, index < string.length else { return nil }
        guard mayBeSpecial(string.character(at: index)) else { return nil }
        guard let scalar = scalar(in: string, at: index) else { return nil }
        let range = NSRange(location: index, length: scalar.utf16.count)
        guard let character = classify(scalar, in: string, range: range) else { return nil }
        return ClassifiedSpecialCharacter(character: character, range: range, scalar: scalar)
    }

    static func mayBeSpecial(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x00...0x08, 0x0B...0x0C, 0x0E...0x1F, 0x7F...0xA0, 0xAD, 0x034F, 0x061C, 0x115F...0x1160, 0x1680,
             0x17B4...0x17B5, 0x180B...0x180F, 0x2000...0x200F, 0x2028...0x202F, 0x205F...0x206F, 0x3000, 0x3164,
             0xD82F, 0xD834, 0xDB40...0xDB43, 0xFE00...0xFE0F, 0xFEFF, 0xFFA0, 0xFFF0...0xFFFB:
            return true
        default:
            return false
        }
    }

    static let layoutControls = CharacterSet(
        charactersIn: "\u{0B}\u{0C}\u{85}\u{2028}\u{2029}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
            + "\u{2066}\u{2067}\u{2068}\u{2069}"
    )

    static func isTextInputControl(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.properties.generalCategory == .control else { return false }
        return !preservedControls.contains(scalar.value)
    }
}

private extension SpecialCharacter {
    static let preservedControls: Set<UInt32> = [0x09, 0x0A, 0x0D]

    static let combiningIgnorables: Set<UInt32> = [
        0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B, 0x180C, 0x180D, 0x180F
    ]

    static let joiners: Set<UInt32> = [0x200C, 0x200D]

    static let emojiTagBase: UInt32 = 0x1F3F4

    static let tagCharacters: ClosedRange<UInt32> = 0xE0020...0xE007F

    static let variationSelectors: [ClosedRange<UInt32>] = [0xFE00...0xFE0F, 0xE0100...0xE01EF]

    static let interlinearAnnotations: ClosedRange<UInt32> = 0xFFF9...0xFFFB

    static let controlLabels: [String] = [
        "NUL", "SOH", "STX", "ETX", "EOT", "ENQ", "ACK", "BEL", "BS", "HT", "LF", "VT", "FF", "CR", "SO", "SI",
        "DLE", "DC1", "DC2", "DC3", "DC4", "NAK", "SYN", "ETB", "CAN", "EM", "SUB", "ESC", "FS", "GS", "RS", "US"
    ]

    static let c1Labels: [String] = [
        "PAD", "HOP", "BPH", "NBH", "IND", "NEL", "SSA", "ESA", "HTS", "HTJ", "VTS", "PLD", "PLU", "RI", "SS2", "SS3",
        "DCS", "PU1", "PU2", "STS", "CCH", "MW", "SPA", "EPA", "SOS", "SGC", "SCI", "CSI", "ST", "OSC", "PM", "APC"
    ]

    static let controlNames: [String] = [
        "null", "start of heading", "start of text", "end of text", "end of transmission", "enquiry",
        "acknowledge", "bell", "backspace", "horizontal tabulation", "line feed", "vertical tabulation",
        "form feed", "carriage return", "shift out", "shift in", "data link escape", "device control one",
        "device control two", "device control three", "device control four", "negative acknowledge",
        "synchronous idle", "end of transmission block", "cancel", "end of medium", "substitute", "escape",
        "file separator", "group separator", "record separator", "unit separator"
    ]

    static let c1Names: [String] = [
        "padding character", "high octet preset", "break permitted here", "no break here", "index", "next line",
        "start of selected area", "end of selected area", "horizontal tabulation set",
        "horizontal tabulation with justification", "vertical tabulation set", "partial line down",
        "partial line up", "reverse index", "single shift two", "single shift three", "device control string",
        "private use one", "private use two", "set transmit state", "cancel character", "message waiting",
        "start of protected area", "end of protected area", "start of string",
        "single graphic character introducer", "single character introducer", "control sequence introducer",
        "string terminator", "operating system command", "privacy message", "application program command"
    ]

    static let formatLabels: [UInt32: String] = [
        0x00AD: "SHY", 0x061C: "ALM", 0x180E: "MVS",
        0x200B: "ZWSP", 0x200C: "ZWNJ", 0x200D: "ZWJ", 0x200E: "LRM", 0x200F: "RLM",
        0x2028: "LSEP", 0x2029: "PSEP",
        0x202A: "LRE", 0x202B: "RLE", 0x202C: "PDF", 0x202D: "LRO", 0x202E: "RLO",
        0x2060: "WJ", 0x2066: "LRI", 0x2067: "RLI", 0x2068: "FSI", 0x2069: "PDI",
        0x206A: "ISS", 0x206B: "ASS", 0x206C: "IAFS", 0x206D: "AAFS", 0x206E: "NADS", 0x206F: "NODS",
        0xFEFF: "BOM", 0xFFF9: "IAA", 0xFFFA: "IAS", 0xFFFB: "IAT"
    ]

    static func classify(_ scalar: Unicode.Scalar, in string: NSString, range: NSRange) -> SpecialCharacter? {
        let value = scalar.value
        let properties = scalar.properties

        switch properties.generalCategory {
        case .control:
            return preservedControls.contains(value) ? nil : .marker(label: controlLabel(for: value))
        case .lineSeparator, .paragraphSeparator:
            return .marker(label: label(for: value))
        case .spaceSeparator:
            return value == 0x20 ? nil : .blankSpace
        default:
            break
        }
        if interlinearAnnotations.contains(value) {
            return .marker(label: label(for: value))
        }
        guard properties.isDefaultIgnorableCodePoint, !isExemptIgnorable(value, in: string, range: range) else {
            return nil
        }
        return .marker(label: label(for: value))
    }

    static func isExemptIgnorable(_ value: UInt32, in string: NSString, range: NSRange) -> Bool {
        if combiningIgnorables.contains(value) { return true }
        if variationSelectors.contains(where: { $0.contains(value) }) { return true }
        if joiners.contains(value) { return joinsNonASCII(in: string, range: range) }
        if tagCharacters.contains(value) { return continuesEmojiTagSequence(in: string, before: range.location) }
        return false
    }

    static func joinsNonASCII(in string: NSString, range: NSRange) -> Bool {
        let before = range.location - 1
        let after = NSMaxRange(range)
        if before >= 0, string.character(at: before) >= 0x80 { return true }
        if after < string.length, string.character(at: after) >= 0x80 { return true }
        return false
    }

    static func continuesEmojiTagSequence(in string: NSString, before location: Int) -> Bool {
        var cursor = location
        while cursor > 0 {
            guard let previous = scalar(in: string, endingAt: cursor) else { return false }
            if previous.value == emojiTagBase { return true }
            guard tagCharacters.contains(previous.value) else { return false }
            cursor -= previous.utf16.count
        }
        return false
    }

    static func controlLabel(for value: UInt32) -> String {
        switch value {
        case 0x00...0x1F:
            return controlLabels[Int(value)]
        case 0x7F:
            return "DEL"
        case 0x80...0x9F:
            return c1Labels[Int(value - 0x80)]
        default:
            return hexLabel(for: value)
        }
    }

    static func controlName(for value: UInt32) -> String? {
        switch value {
        case 0x00...0x1F:
            return controlNames[Int(value)]
        case 0x7F:
            return "delete"
        case 0x80...0x9F:
            return c1Names[Int(value - 0x80)]
        default:
            return nil
        }
    }

    static func label(for value: UInt32) -> String {
        formatLabels[value] ?? hexLabel(for: value)
    }

    static func hexLabel(for value: UInt32) -> String {
        String(format: "%04X", value)
    }

    static func scalar(in string: NSString, at index: Int) -> Unicode.Scalar? {
        let unit = string.character(at: index)
        if UTF16.isLeadSurrogate(unit) {
            guard index + 1 < string.length else { return nil }
            let trail = string.character(at: index + 1)
            guard UTF16.isTrailSurrogate(trail) else { return nil }
            let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(trail) - 0xDC00)
            return Unicode.Scalar(value)
        }
        if UTF16.isTrailSurrogate(unit) { return nil }
        return Unicode.Scalar(unit)
    }

    static func scalar(in string: NSString, endingAt location: Int) -> Unicode.Scalar? {
        guard location > 0 else { return nil }
        let unit = string.character(at: location - 1)
        if UTF16.isTrailSurrogate(unit), location >= 2, UTF16.isLeadSurrogate(string.character(at: location - 2)) {
            return scalar(in: string, at: location - 2)
        }
        return scalar(in: string, at: location - 1)
    }
}

extension String {
    var removingTextInputControlCharacters: String {
        guard unicodeScalars.contains(where: SpecialCharacter.isTextInputControl) else { return self }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: unicodeScalars.lazy.filter { !SpecialCharacter.isTextInputControl($0) })
        return String(kept)
    }
}
