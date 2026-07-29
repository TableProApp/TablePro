//
//  WalkthroughEnvelopeParser.swift
//  TablePro
//

import Foundation

enum WalkthroughEnvelopeParser {
    static let openFence = "---WALKTHROUGH_JSON---"
    static let closeFence = "---WALKTHROUGH_JSON_END---"

    static func parse(from text: String) -> SqlWalkthroughEnvelope? {
        guard let openRange = text.range(of: openFence) else { return nil }
        let afterOpen = openRange.upperBound
        let sliceEnd = text.range(of: closeFence, range: afterOpen..<text.endIndex)?.lowerBound ?? text.endIndex
        let raw = String(text[afterOpen..<sliceEnd])
        let json = stripCodeFence(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = json.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(SqlWalkthroughEnvelope.self, from: data)
        else { return nil }
        return envelope
    }

    static func stripFence(from text: String) -> String {
        guard let openRange = text.range(of: openFence) else { return text }
        return String(text[text.startIndex..<openRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripCodeFence(_ input: String) -> String {
        guard input.hasPrefix("```") else { return input }
        var body = input
        if let firstNewline = body.firstIndex(of: "\n") {
            body = String(body[body.index(after: firstNewline)...])
        }
        if let closingFence = body.range(of: "```", options: .backwards) {
            body = String(body[body.startIndex..<closingFence.lowerBound])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
