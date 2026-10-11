//
//  GeometryValueSniffer.swift
//  TablePro
//

import Foundation
import TableProGeometry

/// Classifies a value too long to read during a selection change by how it opens. The Map segment
/// still reads all of it off the main actor and names what it cannot draw, so a doubtful opening
/// counts as geometry.
internal enum GeometryValueSniffer {
    /// In UTF-8 bytes. A GeoJSON document can put `properties` ahead of its `type` member.
    static let prefixLength = 4_096

    /// Nil when the value does not open like any spelling the spatial readers take.
    static func spatialTextEditor(_ text: String) -> GeometryTextEditor? {
        let head = opening(of: text)
        switch head.first {
        case nil:
            return nil
        case Byte.openBrace:
            return .json
        case Byte.openParen, Byte.openBracket:
            return opensNumberTuple(head) ? .multiLine : nil
        default:
            return opensWKBHex(head) || opensSRIDPrefix(head) || opensWKTKeyword(head) ? .multiLine : nil
        }
    }

    /// A binary cell holds one character per byte, and WKB opens with its byte order, 0 or 1.
    static func opensWKB(binary text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return first.value <= 1
    }

    static func opensGeoJSON(_ text: String) -> Bool {
        let head = opening(of: text)
        guard head.first == Byte.openBrace else { return false }
        var index = head.startIndex
        while index < head.endIndex {
            guard head[index...].starts(with: typeKey) else {
                index += 1
                continue
            }
            index += typeKey.count
            if let name = stringMemberValue(in: head, from: &index),
               geoJSONTypeNames.contains(name.lowercased()) {
                return true
            }
        }
        return false
    }
}

private extension GeometryValueSniffer {
    enum Byte {
        static let openBrace = UInt8(ascii: "{")
        static let openParen = UInt8(ascii: "(")
        static let openBracket = UInt8(ascii: "[")
        static let quote = UInt8(ascii: "\"")
        static let colon = UInt8(ascii: ":")
        static let equals = UInt8(ascii: "=")
    }

    static let typeKey = Array(#""type""#.utf8)

    /// RFC 7946 spells these in mixed case; Elasticsearch hands back lowercase ones as indexed.
    static let geoJSONTypeNames: Set<String> = [
        "point", "multipoint", "linestring", "multilinestring", "polygon", "multipolygon",
        "geometrycollection", "feature", "featurecollection",
    ]

    static func opening(of text: String) -> ArraySlice<UInt8> {
        let head = Array(text.utf8.prefix(prefixLength))
        let start = head.firstIndex { !isWhitespace($0) } ?? head.endIndex
        return head[start...]
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    /// The WKT reader's word class, underscore included, so `POINT_X` is not taken for `POINT`.
    static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
    }

    static func openingWord(_ head: ArraySlice<UInt8>) -> String? {
        String(bytes: head.prefix(while: isWordByte), encoding: .ascii)
    }

    /// The tuple text the ClickHouse geo types arrive as: brackets nested around a number.
    static func opensNumberTuple(_ head: ArraySlice<UInt8>) -> Bool {
        let rest = head.drop(while: { $0 == Byte.openParen || $0 == Byte.openBracket || isWhitespace($0) })
        guard let first = rest.first else { return false }
        return (first >= 0x30 && first <= 0x39) || first == UInt8(ascii: "-") || first == UInt8(ascii: "+")
            || first == UInt8(ascii: ".")
    }

    /// Hex WKB opens with its byte order, `00` or `01`. A WKB header alone is ten digits.
    static func opensWKBHex(_ head: ArraySlice<UInt8>) -> Bool {
        let digits = head.prefix(while: isHexDigit)
        guard digits.count >= 10, digits.first == 0x30 else { return false }
        let second = digits[digits.index(after: digits.startIndex)]
        guard second == 0x30 || second == 0x31 else { return false }
        return head[digits.endIndex...].allSatisfy(isWhitespace)
    }

    static func opensSRIDPrefix(_ head: ArraySlice<UInt8>) -> Bool {
        let word = head.prefix(while: isWordByte)
        guard String(bytes: word, encoding: .ascii)?.uppercased() == "SRID" else { return false }
        return head[word.endIndex...].first { !isWhitespace($0) } == Byte.equals
    }

    /// The readers see the opening word alone. `looksLikeWKT` takes only the types the map draws,
    /// and a curved type the reader refuses by name is still a geometry field.
    static func opensWKTKeyword(_ head: ArraySlice<UInt8>) -> Bool {
        guard let word = openingWord(head), !word.isEmpty else { return false }
        if WKTGeometryReader.looksLikeWKT(word) { return true }
        if case .failure(.unsupportedGeometryType) = WKTGeometryReader.read(word) { return true }
        return false
    }

    /// Reads `: "value"` after a member name, leaving `index` past whatever it consumed.
    static func stringMemberValue(in head: ArraySlice<UInt8>, from index: inout Int) -> String? {
        func skipWhitespace() {
            while index < head.endIndex, isWhitespace(head[index]) { index += 1 }
        }
        skipWhitespace()
        guard index < head.endIndex, head[index] == Byte.colon else { return nil }
        index += 1
        skipWhitespace()
        guard index < head.endIndex, head[index] == Byte.quote else { return nil }
        index += 1
        let start = index
        while index < head.endIndex, head[index] != Byte.quote { index += 1 }
        guard index < head.endIndex else { return nil }
        let value = String(bytes: head[start ..< index], encoding: .utf8)
        index += 1
        return value
    }
}
