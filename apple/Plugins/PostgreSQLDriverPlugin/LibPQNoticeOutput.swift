//
//  LibPQNoticeOutput.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit

struct LibPQNoticeOutput: Sendable {
    static let lineLimit = 10_000
    static let lineByteLimit = 32_767

    private var lines: [String] = []
    private var isTruncated = false

    // libpq's own notices carry no SQLSTATE, and a session-ending message is reported as the lost connection instead.
    static func isOutput(severity: String?, sqlState: String?) -> Bool {
        guard let sqlState, !sqlState.isEmpty else { return false }
        return !LibPQServerMessage.endsSession(severity: severity, sqlState: sqlState)
    }

    // Scalars, not Characters: "\r\n" is one Character, so a message ending in "\r" would keep libpq's newline.
    mutating func record(_ text: String) {
        guard hasRoom() else { return }
        var body = Substring(text).unicodeScalars
        if body.last == "\n" { body.removeLast() }
        guard !body.isEmpty else { return }
        // One line at a time: a notice can hold millions of newlines, and only the first ones fit.
        var start = body.startIndex
        while hasRoom() {
            let end = body[start...].firstIndex(of: "\n") ?? body.endIndex
            lines.append(clipped(body[start..<end]))
            guard end < body.endIndex else { return }
            start = body.index(after: end)
        }
    }

    mutating func take() -> PluginServerOutput {
        let output = PluginServerOutput(lines: lines, isTruncated: isTruncated)
        self = Self()
        return output
    }

    private mutating func hasRoom() -> Bool {
        guard lines.count < Self.lineLimit else {
            isTruncated = true
            return false
        }
        return true
    }

    private mutating func clipped(_ line: Substring.UnicodeScalarView) -> String {
        let bytes = Substring(line).utf8
        guard bytes.count > Self.lineByteLimit else { return String(Substring(line)) }
        isTruncated = true
        var end = bytes.index(bytes.startIndex, offsetBy: Self.lineByteLimit)
        while UTF8.isContinuation(bytes[end]) {
            bytes.formIndex(before: &end)
        }
        return String(Substring(line[..<end]))
    }
}
