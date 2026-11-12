//
//  PipeLineSplitter.swift
//  TablePro
//

import Foundation

// Splits on LF only and decodes whole lines, so a chunk that ends inside a UTF-8 sequence loses nothing
// and a U+2028 inside a JSON string does not cut the line.
struct PipeLineSplitter: Sendable {
    private var pending = Data()

    mutating func lines(appending chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
            lines.append(Self.decode(pending[lineStart ..< newline]))
            lineStart = pending.index(after: newline)
        }
        pending.removeSubrange(pending.startIndex ..< lineStart)
        return lines
    }

    mutating func finish() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : Self.decode(pending)
    }

    private static func decode(_ bytes: Data) -> String {
        let line = bytes.last == 0x0D ? bytes.dropLast() : bytes
        return String(decoding: line, as: UTF8.self) // swiftlint:disable:this optional_data_string_conversion
    }
}
