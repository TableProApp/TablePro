//
//  TextPrefixDecoder.swift
//  TablePro
//

import Foundation

internal enum TextPrefixDecoder {
    struct Decoded {
        let content: String
        let encoding: String.Encoding
        let byteOrderMark: ByteOrderMark?
    }

    static let lookaheadLength = 3

    static func decode(_ bytes: Data, prefixLength: Int, declaredEncoding: String.Encoding? = nil) -> Decoded? {
        guard !bytes.isEmpty, prefixLength > 0 else { return nil }
        if let mark = ByteOrderMark.leading(bytes) {
            return decode(bytes, prefixLength: prefixLength, as: mark.encoding, byteOrderMark: mark)
                ?? decodeAsLatin1(bytes, prefixLength: prefixLength)
        }
        if let declaredEncoding,
           let decoded = decode(bytes, prefixLength: prefixLength, as: declaredEncoding, byteOrderMark: nil) {
            return decoded
        }
        return decode(bytes, prefixLength: prefixLength, as: .utf8, byteOrderMark: nil)
            ?? decodeAsLatin1(bytes, prefixLength: prefixLength)
    }

    private static func decode(
        _ bytes: Data,
        prefixLength: Int,
        as encoding: String.Encoding,
        byteOrderMark: ByteOrderMark?
    ) -> Decoded? {
        let codeUnitLength = encoding.codeUnitLength
        for end in candidateEnds(of: bytes, prefixLength: prefixLength) where end.isMultiple(of: codeUnitLength) {
            if let content = String(data: bytes.prefix(end), encoding: encoding) {
                return Decoded(content: content, encoding: encoding, byteOrderMark: byteOrderMark)
            }
        }
        return nil
    }

    private static func decodeAsLatin1(_ bytes: Data, prefixLength: Int) -> Decoded? {
        guard let content = String(data: bytes.prefix(prefixLength), encoding: .isoLatin1) else { return nil }
        return Decoded(content: content, encoding: .isoLatin1, byteOrderMark: nil)
    }

    private static func candidateEnds(of bytes: Data, prefixLength: Int) -> ClosedRange<Int> {
        guard bytes.count > prefixLength else { return bytes.count...bytes.count }
        return prefixLength...min(bytes.count, prefixLength + lookaheadLength)
    }
}
