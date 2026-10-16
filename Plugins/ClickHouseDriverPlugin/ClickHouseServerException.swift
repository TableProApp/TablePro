//
//  ClickHouseServerException.swift
//  ClickHouseDriverPlugin
//

import Foundation
import TableProPluginKit

/// A streamed read has already had HTTP 200 when a query fails partway, so the server writes the
/// exception into the body and URLSession reports a clean end. What it writes depends on the
/// version, measured from 23.8 to 26.3:
/// - before 24.11, the raw text, `Code: 395. DB::Exception: ... (version 23.8.8.20 (official build))`;
/// - 24.11 to 25.10, `__exception__\r\n` and then the text (ClickHouse#68800);
/// - 25.11 on, a block framed by the `X-ClickHouse-Exception-Tag` header's tag (ClickHouse#88818).
///
/// So the last bytes of the body are held back until it ends, and then read for one of these.
struct ClickHouseStreamTail {
    /// Exception text runs to a few kilobytes, and the tagged block caps it at 16 KiB.
    static let heldByteCount = 65_536

    private var held: [UInt8] = []
    private var headerLinesToPass = 2

    /// The bytes that can be decoded now: the two header lines, and every whole line older than
    /// the held tail.
    mutating func release(_ data: Data) -> Data {
        held.append(contentsOf: data)
        var end = 0
        while headerLinesToPass > 0, let newline = held[end...].firstIndex(of: Self.lineFeed) {
            end = newline + 1
            headerLinesToPass -= 1
        }
        if headerLinesToPass == 0, held.count - end > Self.heldByteCount,
           let newline = held[end..<(held.count - Self.heldByteCount)].lastIndex(of: Self.lineFeed) {
            end = newline + 1
        }
        let released = Data(held[..<end])
        held.removeFirst(end)
        return released
    }

    /// The rest of the rows, or the exception the server ended the body with.
    mutating func finish(
        exceptionTag: String?,
        header: ClickHouseTabSeparatedRowDecoder.Header?
    ) throws -> Data {
        let tail = held
        held = []
        if let message = ClickHouseServerException.framedMessage(in: tail, tag: exceptionTag, header: header) {
            throw ClickHouseError(message: message)
        }
        if let message = ClickHouseServerException.rawMessage(in: tail, header: header) {
            throw ClickHouseError(message: message)
        }
        guard tail.isEmpty || tail.last == Self.lineFeed else {
            throw ClickHouseError(message: String(
                localized: "ClickHouse ended the result partway through a row, so the rows that arrived are incomplete."
            ))
        }
        return Data(tail)
    }

    fileprivate static let lineFeed = UInt8(ascii: "\n")
}

enum ClickHouseServerException {
    private static let marker = Array("__exception__\r\n".utf8)

    /// The tagged block is exact in any output format. The untagged marker is not: a quoted CSV
    /// value can hold a raw carriage return.
    static func throwIfTagged(_ bytes: [UInt8], tag: String?) throws {
        guard let tag, !tag.isEmpty, let message = framedMessage(in: bytes, tag: tag, header: nil) else { return }
        throw ClickHouseError(message: message)
    }

    /// A failure reported by status or by `X-ClickHouse-Exception-Code` can still carry rows
    /// ahead of the text: 25.10 and later compress by default, and a failure before the first
    /// flush comes back as HTTP 500 with the rows written so far. The text is the end of the body.
    static func message(inFailureBody body: String) -> String {
        let bytes = Array(body.utf8)
        let text = framedMessage(in: bytes, tag: nil, header: nil)
            ?? rawExceptionStart(in: bytes).map { text(of: bytes[$0...]) }
            ?? body
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The tagged block (25.11 on) or the untagged marker (24.11 to 25.10). A raw carriage return
    /// never appears in TabSeparated data, so the marker cannot be a value, unless the user's
    /// profile turned on CRLF line ends, which the header lines then show.
    fileprivate static func framedMessage(
        in bytes: [UInt8],
        tag: String?,
        header: ClickHouseTabSeparatedRowDecoder.Header?
    ) -> String? {
        if let tag, !tag.isEmpty {
            let opening = marker + Array("\(tag)\r\n".utf8)
            guard let start = firstRange(of: opening, in: bytes) else { return nil }
            var message = bytes[start.upperBound...]
            if let closing = firstRange(of: Array(" \(tag)\r\n".utf8), in: Array(message)),
               let lengthLine = message[..<(message.startIndex + closing.lowerBound)].lastIndex(of: ClickHouseStreamTail.lineFeed) {
                message = message[..<lengthLine]
            }
            return text(of: message)
        }
        if header?.columnTypeNames.last?.hasSuffix("\r") == true { return nil }
        guard let start = firstRange(of: marker, in: bytes) else { return nil }
        return text(of: bytes[start.upperBound...])
    }

    /// Before 24.11 the text is written raw after the last row, so a legitimate value can read
    /// the same: a one-column export of `system.query_log.exception` does. It is reported only
    /// when the lines from the last `Code:` line on cannot be rows of this result, and otherwise
    /// left as rows: a one-column String result failing on a message with no quote is missed.
    fileprivate static func rawMessage(
        in bytes: [UInt8],
        header: ClickHouseTabSeparatedRowDecoder.Header?
    ) -> String? {
        guard let start = rawExceptionStart(in: bytes) else { return nil }
        let block = bytes[start...]
        let lines = block.split(separator: ClickHouseStreamTail.lineFeed, omittingEmptySubsequences: true)
        guard let lastLine = lines.last, endsWithVersion(String(decoding: lastLine, as: UTF8.self)) else {
            return nil
        }
        guard let header else { return text(of: block) }

        let columnCount = header.columns.count
        let tab = UInt8(ascii: "\t")
        let isWrongWidth = lines.contains { line in line.count(where: { $0 == tab }) + 1 != columnCount }
        guard !isWrongWidth else { return text(of: block) }
        guard columnCount == 1, let type = header.columnTypeNames.first else { return nil }
        guard isStringFamily(type) else { return text(of: block) }
        /// TabSeparated writes a quote inside a String as `\'`, and exception text quotes names.
        let quote = UInt8(ascii: "'")
        let backslash = UInt8(ascii: "\\")
        let hasRawQuote = block.indices.contains { index in
            block[index] == quote && (index == block.startIndex || block[index - 1] != backslash)
        }
        return hasRawQuote ? text(of: block) : nil
    }

    private static let rawPrefixes: [String] = [
        #"^Code: \d+\. "#,
        #"^Code: \d+, e\.displayText\(\) = "#,
        #"^Poco::Exception\. Code: "#,
        #"^std::exception\. Code: "#,
        #"^Unknown exception\. Code: "#,
    ]

    private static let rawPrefixPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: rawPrefixes.map { "(?:\($0))" }.joined(separator: "|")
    )

    private static let versionSuffixPattern: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\(version [0-9][^()]*(?: \([A-Za-z ]+\))?\)\s*$"#
    )

    /// Where the last line that opens an exception begins.
    private static func rawExceptionStart(in bytes: [UInt8]) -> Int? {
        guard let rawPrefixPattern else { return nil }
        var lineStart = bytes.endIndex
        while lineStart > bytes.startIndex {
            let previous = bytes[..<lineStart].dropLast().lastIndex(of: ClickHouseStreamTail.lineFeed)
            let start = previous.map { $0 + 1 } ?? bytes.startIndex
            let line = String(decoding: bytes[start..<min(start + 64, bytes.endIndex)], as: UTF8.self)
            if rawPrefixPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                return start
            }
            lineStart = start
        }
        return nil
    }

    private static func endsWithVersion(_ line: String) -> Bool {
        guard let versionSuffixPattern else { return false }
        return versionSuffixPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// A profile with CRLF line ends leaves the carriage return on the last header field.
    private static func isStringFamily(_ type: String) -> Bool {
        let bare = ClickHousePluginDriver.unwrapTypeWrappers(type.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        return bare == "String" || bare.hasPrefix("FixedString(")
    }

    private static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let first = needle[0]
        var index = haystack.startIndex
        while let candidate = haystack[index...].firstIndex(of: first) {
            guard candidate + needle.count <= haystack.endIndex else { return nil }
            if haystack[candidate..<(candidate + needle.count)].elementsEqual(needle) {
                return candidate..<(candidate + needle.count)
            }
            index = candidate + 1
        }
        return nil
    }

    private static func text(of bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) // swiftlint:disable:this optional_data_string_conversion
    }
}
