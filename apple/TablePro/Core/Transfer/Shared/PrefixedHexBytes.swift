import Foundation

// The form a copy, a CSV export and an XLSX export write bytes in, read strictly: a copy cut short with `…`
// or text that only starts like hex is not bytes.
nonisolated enum PrefixedHexBytes {
    static func hasPrefix(_ text: String) -> Bool {
        text.hasPrefix("0x") || text.hasPrefix("0X")
    }

    static func bytes(from text: String) -> Data? {
        guard hasPrefix(text) else { return nil }
        let digits = text.utf8.dropFirst(2)
        guard digits.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var high: UInt8?
        for character in digits {
            guard let nibble = nibble(character) else { return nil }
            if let pending = high {
                bytes.append(pending << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return Data(bytes)
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return character - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}

nonisolated extension ImportTargetValues.PrefixedHex {
    init(reading text: String) {
        guard PrefixedHexBytes.hasPrefix(text) else {
            self = .notHex
            return
        }
        self = PrefixedHexBytes.bytes(from: text).map(Self.bytes) ?? .malformed
    }
}
