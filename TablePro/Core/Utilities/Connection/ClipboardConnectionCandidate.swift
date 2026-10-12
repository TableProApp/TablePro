//
//  ClipboardConnectionCandidate.swift
//  TablePro
//

import Foundation

struct ClipboardConnectionCandidate {
    let scheme: String
    let parsed: ParsedConnectionURL

    init?(clipboardText: String) {
        let firstLine = clipboardText
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let schemeEnd = firstLine.range(of: "://"),
              case .success(let parsed) = ConnectionURLParser.parse(firstLine),
              !parsed.host.isEmpty
        else { return nil }
        self.scheme = firstLine[firstLine.startIndex..<schemeEnd.lowerBound].lowercased()
        self.parsed = parsed
    }
}
