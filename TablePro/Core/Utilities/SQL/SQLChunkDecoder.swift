//
//  SQLChunkDecoder.swift
//  TablePro
//

import Foundation

/// Turns a file's bytes into text one chunk at a time, holding back whatever runs off the end of
/// a chunk until the next one arrives.
///
/// `String(data:encoding:)` is the whole of Foundation's decoding API and it has no way to report
/// a partial character, so three measured behaviours have to be worked around rather than caught.
///
/// A chunk of UTF-16 carrying no byte order mark decodes as big-endian. The mark is at the start
/// of the file, so only the first chunk has one, and every chunk after it in a little-endian file
/// came back byte-swapped: a UTF-16 dump over 64 KiB imported as CJK from its first chunk
/// boundary on, with nothing raised. The byte order is therefore settled once, from the mark, and
/// every chunk after that is decoded with the explicit variant. Stripping the mark becomes this
/// type's job at the same time, because only the `.utf16` spelling consumes one.
///
/// A chunk holding an odd number of UTF-16 bytes decodes the even part and drops the last byte
/// without failing, so the alignment is held back here rather than left for the decoder to
/// notice.
///
/// A UTF-16 surrogate pair split across a boundary fails the whole chunk, as does a partial UTF-8
/// sequence, so a chunk that will not decode gives its last few bytes back to the next one. How
/// many is derived from the encoding rather than assumed: only UTF-8 was handled before, so a
/// character split across a boundary in any other multi-byte encoding failed the import outright.
struct SQLChunkDecoder {
    private let declaredEncoding: String.Encoding
    private var resolvedEncoding: String.Encoding?
    private var unitSize = 1
    private var maximumTrim = 0
    private var pendingTail = Data()

    var hasPendingBytes: Bool { !pendingTail.isEmpty }

    init(encoding: String.Encoding) {
        declaredEncoding = encoding
    }

    mutating func decode(_ rawData: Data) -> String? {
        var data = pendingTail
        data.append(rawData)
        pendingTail.removeAll(keepingCapacity: true)

        let encoding = resolveIfNeeded(startingWith: &data)

        var carried = Data()
        let misalignment = data.count % unitSize
        if misalignment > 0 {
            carried = Data(data.suffix(misalignment))
            data = Data(data.prefix(data.count - misalignment))
        }

        if let decoded = String(data: data, encoding: encoding) {
            pendingTail = carried
            return decoded
        }

        var trim = unitSize
        while trim <= maximumTrim && data.count >= trim {
            let head = Data(data.prefix(data.count - trim))
            if head.isEmpty {
                pendingTail = data + carried
                return ""
            }
            if let decoded = String(data: head, encoding: encoding) {
                pendingTail = Data(data.suffix(trim)) + carried
                return decoded
            }
            trim += unitSize
        }
        return nil
    }

    private mutating func resolveIfNeeded(startingWith data: inout Data) -> String.Encoding {
        if let resolvedEncoding { return resolvedEncoding }

        let resolution = Self.resolve(declaredEncoding, startingWith: data)
        resolvedEncoding = resolution.encoding
        unitSize = Self.unitSize(of: resolution.encoding)
        maximumTrim = Self.maximumTrim(of: resolution.encoding, unitSize: unitSize)
        if resolution.byteOrderMarkLength > 0, data.count >= resolution.byteOrderMarkLength {
            data = Data(data.dropFirst(resolution.byteOrderMarkLength))
        }
        return resolution.encoding
    }

    private struct Resolution {
        let encoding: String.Encoding
        let byteOrderMarkLength: Int
    }

    /// `.utf8` is absent on purpose: Foundation consumes a UTF-8 mark itself, measured.
    private static func resolve(_ encoding: String.Encoding, startingWith data: Data) -> Resolution {
        if let mark = ByteOrderMark.leading(data, allowedBy: encoding) {
            return Resolution(encoding: mark.byteOrderedEncoding, byteOrderMarkLength: mark.length)
        }
        return Resolution(encoding: unmarkedByteOrder(of: encoding), byteOrderMarkLength: 0)
    }

    private static func unmarkedByteOrder(of encoding: String.Encoding) -> String.Encoding {
        switch encoding {
        case .utf16:
            return .utf16BigEndian
        case .utf32:
            return .utf32BigEndian
        default:
            return encoding
        }
    }

    private static func unitSize(of encoding: String.Encoding) -> Int {
        switch encoding {
        case .utf16, .utf16LittleEndian, .utf16BigEndian:
            return 2
        case .utf32, .utf32LittleEndian, .utf32BigEndian:
            return 4
        default:
            return 1
        }
    }

    /// `CFStringGetMaximumSizeForEncoding` counts bytes per UTF-16 code unit, so it is asked for
    /// two of them: that is one Unicode scalar, which is the largest thing a boundary can cut in
    /// half. It over-reports for several encodings, which costs a decode attempt that fails and
    /// never loses a byte, since a trimmed byte goes back on the front of the next chunk.
    private static func maximumTrim(of encoding: String.Encoding, unitSize: Int) -> Int {
        let cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        guard cfEncoding != kCFStringEncodingInvalidId else { return 0 }
        let perScalar = Int(CFStringGetMaximumSizeForEncoding(2, cfEncoding))
        guard perScalar > unitSize else { return 0 }
        return min(perScalar, 8) - unitSize
    }
}
