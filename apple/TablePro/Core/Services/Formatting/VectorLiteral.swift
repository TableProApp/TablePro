//
//  VectorLiteral.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// pgvector's text form: `[1,2.5,-3e-05]` for vector and halfvec, `{1:2,3:0.5}/5` for sparsevec (1-based indices).
internal struct VectorLiteral: Equatable, Sendable {
    internal struct Element: Equatable, Sendable, Identifiable {
        internal let index: Int
        internal let text: String

        internal var id: Int { index }
    }

    internal let dimensions: Int
    internal let elements: [Element]
    internal let isSparse: Bool

    // Range stays the server's call: vector and halfvec hold different ranges and the type is not known here.
    internal static func parse(_ text: String) -> VectorLiteral? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") { return parseDense(trimmed) }
        if trimmed.hasPrefix("{") { return parseSparse(trimmed) }
        return nil
    }

    private static func parseDense(_ text: String) -> VectorLiteral? {
        guard text.count >= 2, text.hasSuffix("]") else { return nil }
        let body = text.dropFirst().dropLast()
        guard !body.allSatisfy(\.isWhitespace) else {
            return VectorLiteral(dimensions: 0, elements: [], isSparse: false)
        }
        var elements: [Element] = []
        for (offset, token) in body.split(separator: ",", omittingEmptySubsequences: false).enumerated() {
            guard let number = finiteNumber(token) else { return nil }
            elements.append(Element(index: offset + 1, text: number))
        }
        return VectorLiteral(dimensions: elements.count, elements: elements, isSparse: false)
    }

    private static func parseSparse(_ text: String) -> VectorLiteral? {
        guard let close = text.lastIndex(of: "}") else { return nil }
        let tail = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
        guard tail.hasPrefix("/"),
              let dimensions = Int(tail.dropFirst().trimmingCharacters(in: .whitespaces)),
              dimensions > 0 else { return nil }
        let body = text[text.index(after: text.startIndex)..<close]
        guard !body.allSatisfy(\.isWhitespace) else {
            return VectorLiteral(dimensions: dimensions, elements: [], isSparse: true)
        }
        var elements: [Element] = []
        var seen: Set<Int> = []
        for token in body.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let index = Int(pair[0].trimmingCharacters(in: .whitespaces)),
                  (1...dimensions).contains(index),
                  seen.insert(index).inserted,
                  let number = finiteNumber(pair[1]) else { return nil }
            elements.append(Element(index: index, text: number))
        }
        return VectorLiteral(
            dimensions: dimensions,
            elements: elements.sorted { $0.index < $1.index },
            isSparse: true
        )
    }

    private static func finiteNumber(_ token: Substring) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value.isFinite else { return nil }
        return trimmed
    }

    internal var jsonText: String {
        if isSparse {
            let members = elements.map { "\"\($0.index)\":\(Self.jsonNumber($0.text))" }
            return "{" + members.joined(separator: ",") + "}"
        }
        return "[" + elements.map { Self.jsonNumber($0.text) }.joined(separator: ",") + "]"
    }

    private static func jsonNumber(_ text: String) -> String {
        JsonNumberNormalizer.numberLiteral(from: text) ?? Double(text).map { "\($0)" } ?? text
    }
}

// MARK: - Grid summary

extension VectorLiteral {
    // The grid formats every row it prewarms and a 1,536-dimension value is 15 KB, so this is one byte pass
    // that keeps only the leading elements.
    internal static func summary(of text: String, leadingCount: Int = 3) -> String? {
        guard let shape = VectorTextShape(text, keeping: leadingCount) else { return nil }
        let (open, close) = shape.isSparse ? ("{", "}") : ("[", "]")
        var shown = shape.leading.joined(separator: ", ")
        if shape.elementCount > shape.leading.count {
            shown += shape.leading.isEmpty ? "…" : ", …"
        }
        return "\(open)\(shown)\(close) \(dimensionsLabel(shape.dimensions))"
    }

    internal static func isVectorText(_ text: String) -> Bool {
        VectorTextShape(text, keeping: 0) != nil
    }

    internal static func dimensionsLabel(_ count: Int) -> String {
        count == 1 ? String(localized: "1 dim") : String(format: String(localized: "%lld dims"), count)
    }
}

private struct VectorTextShape {
    let isSparse: Bool
    let elementCount: Int
    let dimensions: Int
    let leading: [String]

    private static let comma = UInt8(ascii: ",")
    private static let colon = UInt8(ascii: ":")
    private static let slash = UInt8(ascii: "/")

    init?(_ text: String, keeping leadingCount: Int) {
        let bytes = Array(text.utf8)
        var start = 0
        var end = bytes.count
        while start < end, Self.isWhitespace(bytes[start]) { start += 1 }
        while end > start, Self.isWhitespace(bytes[end - 1]) { end -= 1 }
        guard end - start >= 2 else { return nil }

        let isSparse: Bool
        let bodyEnd: Int
        let declaredDimensions: Int?
        switch bytes[start] {
        case UInt8(ascii: "["):
            guard bytes[end - 1] == UInt8(ascii: "]") else { return nil }
            isSparse = false
            bodyEnd = end - 1
            declaredDimensions = nil
        case UInt8(ascii: "{"):
            guard let close = bytes[start..<end].lastIndex(of: UInt8(ascii: "}")),
                  let declared = Self.sparseDimensions(bytes[(close + 1)..<end]) else { return nil }
            isSparse = true
            bodyEnd = close
            declaredDimensions = declared
        default:
            return nil
        }

        var leading: [String] = []
        var count = 0
        if !bytes[(start + 1)..<bodyEnd].allSatisfy(Self.isWhitespace) {
            var tokenStart = start + 1
            for index in tokenStart...bodyEnd where index == bodyEnd || bytes[index] == Self.comma {
                let token = bytes[tokenStart..<index]
                guard Self.isElement(token, sparse: isSparse) else { return nil }
                if leading.count < leadingCount {
                    leading.append(Self.display(token, sparse: isSparse))
                }
                count += 1
                tokenStart = index + 1
            }
        }
        self.isSparse = isSparse
        self.elementCount = count
        self.dimensions = declaredDimensions ?? count
        self.leading = leading
    }

    private static func sparseDimensions(_ tail: ArraySlice<UInt8>) -> Int? {
        let trimmed = tail.drop(while: isWhitespace)
        guard trimmed.first == slash else { return nil }
        let digits = trimmed.dropFirst().drop(while: isWhitespace)
        guard !digits.isEmpty, digits.allSatisfy(isDigit) else { return nil }
        return String(bytes: digits, encoding: .utf8).flatMap { Int($0) }
    }

    private static func isElement(_ token: ArraySlice<UInt8>, sparse: Bool) -> Bool {
        guard sparse else { return isNumber(token) }
        guard let colonIndex = token.firstIndex(of: colon) else { return false }
        let index = trimmed(token[token.startIndex..<colonIndex])
        return !index.isEmpty && index.allSatisfy(isDigit) && isNumber(token[(colonIndex + 1)...])
    }

    // Decimal spellings only, which is what pgvector and the other engines with a bracketed vector print.
    // Space is allowed around a number, never inside one.
    private static func isNumber(_ token: ArraySlice<UInt8>) -> Bool {
        let number = trimmed(token)
        return number.contains(where: isDigit) && number.allSatisfy(isNumberByte)
    }

    private static func display(_ token: ArraySlice<UInt8>, sparse: Bool) -> String {
        guard sparse, let colonIndex = token.firstIndex(of: colon) else { return text(trimmed(token)) }
        return text(trimmed(token[token.startIndex..<colonIndex])) + ":" + text(trimmed(token[(colonIndex + 1)...]))
    }

    private static func isNumberByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "-"), UInt8(ascii: "+"),
             UInt8(ascii: "e"), UInt8(ascii: "E"):
            return true
        default:
            return false
        }
    }

    private static func trimmed(_ token: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var slice = token.drop(while: isWhitespace)
        while let last = slice.last, isWhitespace(last) { slice = slice.dropLast() }
        return slice
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? ""
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
