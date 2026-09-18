//
//  PluginTextEncoding.swift
//  TableProPluginKit
//

import Foundation

/// The encoding an export writes its text in.
///
/// Only encodings that write the same bytes whether a file is produced in one piece or a line at a
/// time belong here. `String.Encoding.utf16`, `.utf32` and `.unicode` prepend a byte order mark to
/// the result of *every* `data(using:)` call, so an exporter that encodes one row at a time would
/// write a mark before each row; an explicit-endian variant would be needed instead, with the mark
/// left to `byteOrderMark` and the exporter's first write.
public enum PluginTextEncoding: String, Sendable, Codable, CaseIterable, Identifiable {
    case utf8
    case isoLatin1
    case windowsCP1252

    public var id: String { rawValue }

    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .isoLatin1: return .isoLatin1
        case .windowsCP1252: return .windowsCP1252
        }
    }

    /// The prologue a file in this encoding may open with. Empty for an encoding that has no mark,
    /// which is what makes `supportsByteOrderMark` an honest answer rather than a second list.
    public var byteOrderMark: [UInt8] {
        switch self {
        case .utf8: return [0xEF, 0xBB, 0xBF]
        case .isoLatin1, .windowsCP1252: return []
        }
    }

    public var supportsByteOrderMark: Bool { !byteOrderMark.isEmpty }

    /// The name the encoding is known by, which is a technical term rather than prose and is
    /// therefore the same in every language. It matches what the CSV import picker already spells.
    public var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .isoLatin1: return "ISO Latin 1"
        case .windowsCP1252: return "Windows-1252"
        }
    }
}

/// Bytes in a chosen encoding, and the characters that encoding could not represent.
public struct PluginEncodedText: Sendable {
    public let data: Data

    /// Distinct characters the encoding could not represent, first met first. Each was written as
    /// `?`, the only substitute Foundation produces: sweeping every scalar to U+10FFF for both
    /// `isoLatin1` and `windowsCP1252` yields `0x3F` and nothing else, and never a byte a CSV
    /// reader treats as a delimiter, a quote or a line break.
    public let unrepresented: [Character]

    public init(data: Data, unrepresented: [Character]) {
        self.data = data
        self.unrepresented = unrepresented
    }
}

/// An encoding that produced no bytes at all for text that is not empty.
///
/// Not reachable through any encoding `PluginTextEncoding` offers, since a lossy conversion to a
/// single-byte encoding always succeeds. It exists so that a future case cannot fail quietly: the
/// alternative is a caller that writes an empty line and reports a clean export.
public struct PluginTextEncodingFailure: Error, LocalizedError {
    public let encodingName: String

    public init(encodingName: String) {
        self.encodingName = encodingName
    }

    public var errorDescription: String? {
        String(format: String(localized: "Could not write this text as %@."), encodingName)
    }
}

/// Text to bytes, saying what it had to give up.
///
/// `String.data(using:)` is all or nothing: one unrepresentable scalar makes it return nil for the
/// whole string. `allowLossyConversion` writes the substitute instead but reports nothing, which is
/// the silence this exists to break.
public enum PluginTextEncoder {
    private static let scanBufferSize = 8_192

    /// `detectingUnrepresented` is the caller's way to stop paying for an answer it already has.
    /// The scan costs around 1.3µs per unrepresentable character and runs on every line, so an
    /// export of CJK text to a Latin encoding spends minutes naming the same characters over and
    /// over. A caller that only reports a bounded set turns it off once that set is full.
    public static func encode(
        _ text: String,
        as encoding: PluginTextEncoding,
        detectingUnrepresented: Bool = true
    ) throws -> PluginEncodedText {
        let target = encoding.stringEncoding
        if let data = text.data(using: target, allowLossyConversion: false) {
            return PluginEncodedText(data: data, unrepresented: [])
        }
        guard let data = text.data(using: target, allowLossyConversion: true) else {
            throw PluginTextEncodingFailure(encodingName: encoding.displayName)
        }
        guard detectingUnrepresented else {
            return PluginEncodedText(data: data, unrepresented: [])
        }
        return PluginEncodedText(data: data, unrepresented: unrepresented(in: text, as: target))
    }

    /// Walks by grapheme cluster rather than by scalar, because Foundation composes before it
    /// converts: `a` followed by U+0301 encodes to `0xE1` in ISO Latin 1 while U+0301 alone does
    /// not, so a per-scalar check names characters that came through intact.
    ///
    /// `getBytes(...remaining:)` converts the longest run it can and reports where it stopped, so
    /// each call skips a whole encodable run instead of testing one character at a time. Measured
    /// on a 200 KB field holding one unrepresentable character: 0.33ms against 26ms. A stop is not
    /// always a failure, since the buffer fills too, so the cluster at the stop is tested before it
    /// is blamed.
    private static func unrepresented(in text: String, as encoding: String.Encoding) -> [Character] {
        let source = text as NSString
        var found: [Character] = []
        var seen: Set<Character> = []
        var location = 0
        var buffer = [UInt8](repeating: 0, count: scanBufferSize)

        while location < source.length {
            var used = 0
            var remaining = NSRange(location: location, length: 0)
            let scanned = NSRange(location: location, length: source.length - location)
            _ = source.getBytes(
                &buffer,
                maxLength: buffer.count,
                usedLength: &used,
                encoding: encoding.rawValue,
                options: [],
                range: scanned,
                remaining: &remaining
            )
            guard remaining.length > 0, remaining.location < source.length else { return found }

            let cluster = source.rangeOfComposedCharacterSequence(at: remaining.location)
            let candidate = source.substring(with: cluster)
            if candidate.data(using: encoding, allowLossyConversion: false) == nil,
               let character = candidate.first, seen.insert(character).inserted {
                found.append(character)
            }

            let next = cluster.location + cluster.length
            guard next > location else { return found }
            location = next
        }
        return found
    }
}
