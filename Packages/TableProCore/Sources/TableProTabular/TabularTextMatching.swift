import Foundation
import TableProTabularIO

public struct TabularNeedle: Sendable {
    public let text: String
    public let bytes: [UInt8]
    public let foldedBytes: [UInt8]
    public let isASCII: Bool

    public init(_ text: String) {
        self.text = text
        let utf8 = Array(text.utf8)
        bytes = utf8
        foldedBytes = utf8.map(TabularValueGrammar.asciiLowercase)
        isASCII = utf8.allSatisfy { $0 < 0x80 }
    }

    public var isEmpty: Bool { bytes.isEmpty }
}

public enum TabularTextMatching {
    public static func contains(
        _ haystack: UnsafeBufferPointer<UInt8>,
        _ needle: TabularNeedle,
        caseSensitive: Bool,
        diacriticSensitive: Bool = true
    ) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.bytes.count || !caseSensitive else { return false }
        let asciiPair = needle.isASCII && TabularValueGrammar.isASCII(haystack)
        if caseSensitive, diacriticSensitive || asciiPair {
            return firstIndex(of: needle.bytes, in: haystack, folding: false) != nil
        }
        if asciiPair {
            return firstIndex(of: needle.foldedBytes, in: haystack, folding: true) != nil
        }
        return string(haystack).range(of: needle.text, options: options(caseSensitive, diacriticSensitive)) != nil
    }

    public static func hasPrefix(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: TabularNeedle, caseSensitive: Bool) -> Bool {
        guard !needle.isEmpty else { return true }
        if caseSensitive {
            guard haystack.count >= needle.bytes.count else { return false }
            return equalBytes(haystack, from: 0, needle.bytes, folding: false)
        }
        if needle.isASCII, TabularValueGrammar.isASCII(haystack) {
            guard haystack.count >= needle.bytes.count else { return false }
            return equalBytes(haystack, from: 0, needle.foldedBytes, folding: true)
        }
        return string(haystack).range(of: needle.text, options: [.caseInsensitive, .anchored]) != nil
    }

    public static func hasSuffix(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: TabularNeedle, caseSensitive: Bool) -> Bool {
        guard !needle.isEmpty else { return true }
        if caseSensitive {
            guard haystack.count >= needle.bytes.count else { return false }
            return equalBytes(haystack, from: haystack.count - needle.bytes.count, needle.bytes, folding: false)
        }
        if needle.isASCII, TabularValueGrammar.isASCII(haystack) {
            guard haystack.count >= needle.bytes.count else { return false }
            return equalBytes(haystack, from: haystack.count - needle.bytes.count, needle.foldedBytes, folding: true)
        }
        return string(haystack).range(of: needle.text, options: [.caseInsensitive, .anchored, .backwards]) != nil
    }

    public static func compare(
        _ lhs: UnsafeBufferPointer<UInt8>,
        _ rhs: TabularNeedle,
        caseSensitive: Bool
    ) -> ComparisonResult {
        let asciiPair = rhs.isASCII && TabularValueGrammar.isASCII(lhs)
        guard asciiPair else {
            return string(lhs).compare(rhs.text, options: caseSensitive ? [.literal] : [.caseInsensitive])
        }
        let right = caseSensitive ? rhs.bytes : rhs.foldedBytes
        let shared = min(lhs.count, right.count)
        for index in 0..<shared {
            let left = caseSensitive ? lhs[index] : TabularValueGrammar.asciiLowercase(lhs[index])
            if left < right[index] { return .orderedAscending }
            if left > right[index] { return .orderedDescending }
        }
        if lhs.count < right.count { return .orderedAscending }
        if lhs.count > right.count { return .orderedDescending }
        return .orderedSame
    }

    public static func firstIndex(
        of needle: [UInt8],
        in haystack: UnsafeBufferPointer<UInt8>,
        folding: Bool,
        from start: Int = 0
    ) -> Int? {
        let needleCount = needle.count
        guard needleCount > 0, haystack.count - start >= needleCount else { return nil }
        let first = needle[0]
        var index = start
        let last = haystack.count - needleCount
        while index <= last {
            let byte = folding ? TabularValueGrammar.asciiLowercase(haystack[index]) : haystack[index]
            if byte == first, equalBytes(haystack, from: index, needle, folding: folding) {
                return index
            }
            index += 1
        }
        return nil
    }

    public static func string(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        TabularTextCodec.utf8String(bytes)
    }

    @inline(__always)
    private static func equalBytes(
        _ haystack: UnsafeBufferPointer<UInt8>,
        from start: Int,
        _ needle: [UInt8],
        folding: Bool
    ) -> Bool {
        for offset in 0..<needle.count {
            let byte = haystack[start + offset]
            let candidate = folding ? TabularValueGrammar.asciiLowercase(byte) : byte
            if candidate != needle[offset] { return false }
        }
        return true
    }

    private static func options(_ caseSensitive: Bool, _ diacriticSensitive: Bool) -> String.CompareOptions {
        var options: String.CompareOptions = caseSensitive ? [.literal] : [.caseInsensitive]
        if !diacriticSensitive {
            options.insert(.diacriticInsensitive)
        }
        return options
    }
}
