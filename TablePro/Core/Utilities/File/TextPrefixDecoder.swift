//
//  TextPrefixDecoder.swift
//  TablePro
//

import Foundation

internal enum TextPrefixDecoder {
    struct Decoded {
        let content: String
        let encoding: String.Encoding
    }

    static let lookaheadLength = 3

    static func decode(_ bytes: Data, prefixLength: Int) -> Decoded? {
        guard !bytes.isEmpty, prefixLength > 0 else { return nil }
        let mark = ByteOrderMark.leading(bytes)
        let encoding = mark?.encoding ?? .utf8
        let codeUnitLength = mark?.codeUnitLength ?? 1
        if let content = decode(bytes, prefixLength: prefixLength, as: encoding, codeUnitLength: codeUnitLength) {
            return Decoded(content: content, encoding: encoding)
        }
        guard let content = String(data: bytes.prefix(prefixLength), encoding: .isoLatin1) else { return nil }
        return Decoded(content: content, encoding: .isoLatin1)
    }

    private static func decode(
        _ bytes: Data,
        prefixLength: Int,
        as encoding: String.Encoding,
        codeUnitLength: Int
    ) -> String? {
        for end in candidateEnds(of: bytes, prefixLength: prefixLength) where end.isMultiple(of: codeUnitLength) {
            if let content = String(data: bytes.prefix(end), encoding: encoding) {
                return content
            }
        }
        return nil
    }

    private static func candidateEnds(of bytes: Data, prefixLength: Int) -> ClosedRange<Int> {
        guard bytes.count > prefixLength else { return bytes.count...bytes.count }
        return prefixLength...min(bytes.count, prefixLength + lookaheadLength)
    }
}
