//
//  BinaryTextDecoder.swift
//  TablePro
//
//  Reads binary cell bytes as text, and says no when they are not text.
//

import Foundation

internal enum BinaryTextDecoder {
    /// A UTF-8 scalar is at most four bytes, so this always covers the grid's 10,000 character cap
    /// and a LONGBLOB never builds a multi-gigabyte String on the main thread.
    static let maxDisplayBytes = 40_000

    /// Detection only has to recognise text, not render it, and it runs over ten sample rows of
    /// every binary column in the result before the grid draws.
    static let maxProbeBytes = 512

    static let truncationMarker = "…"

    /// The decoded text, or nil when the bytes are not text and belong in the hex fallback.
    ///
    /// A value cut at `maxBytes` may end mid-sequence, so the tail is allowed to give up three
    /// bytes, and the result carries `truncationMarker` so a caller writing it to the clipboard
    /// cannot pass off a prefix as the whole value. A whole value gives up nothing: dropping bytes
    /// there would accept binary that happens to start with readable characters.
    static func decode(
        _ data: Data,
        columnType: ColumnType? = nil,
        maxBytes: Int = maxDisplayBytes
    ) -> String? {
        guard data.count > maxBytes else {
            return decodeWhole(trimmingPadding(data, columnType: columnType))
        }
        guard let text = decodeTruncated(data.prefix(maxBytes)) else { return nil }
        return text + truncationMarker
    }

    /// The same answer for a driver that hands binary content over as a string, where each
    /// character stands for one stored byte.
    static func decode(
        isoLatin1 value: String,
        columnType: ColumnType? = nil,
        maxBytes: Int = maxDisplayBytes
    ) -> String? {
        guard let data = value.data(using: .isoLatin1) else { return nil }
        return decode(data, columnType: columnType, maxBytes: maxBytes)
    }

    /// `BINARY(N)` right-pads with `0x00`, and trimming that run is what lets a fixed-width column
    /// holding text read as text at all. No other binary type pads, so a trailing NUL in a `BLOB`
    /// or a `VARBINARY` is stored data: trimming it there would report `0x6100` as `a`.
    static func padsToFixedWidth(_ columnType: ColumnType?) -> Bool {
        guard let columnType, columnType.isBlobType, let raw = columnType.rawType?.uppercased() else { return false }
        return raw.prefix { $0 != "(" }.trimmingCharacters(in: .whitespaces) == "BINARY"
    }

    private static func trimmingPadding(_ data: Data, columnType: ColumnType?) -> Data {
        guard padsToFixedWidth(columnType) else { return data }
        guard let lastContent = data.lastIndex(where: { $0 != 0 }) else { return Data() }
        return data.prefix(through: lastContent)
    }

    private static func decodeWhole(_ data: Data) -> String? {
        guard !data.isEmpty else { return "" }
        guard let text = String(data: data, encoding: .utf8), isReadable(text) else { return nil }
        return text
    }

    private static func decodeTruncated(_ data: Data) -> String? {
        for dropped in 0...3 where data.count > dropped {
            let candidate = data.dropLast(dropped)
            guard let text = String(data: candidate, encoding: .utf8) else { continue }
            return isReadable(text) ? text : nil
        }
        return nil
    }

    /// C0 controls, DEL and a lone NUL are what separates a stored string from a hash, an image
    /// header or a packed integer that happens to decode.
    private static func isReadable(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                continue
            case 0x00...0x1F, 0x7F:
                return false
            default:
                continue
            }
        }
        return true
    }
}
