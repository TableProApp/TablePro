import Foundation

enum TrinoResponseText {
    private static let scanLimit = 8_192

    private static let plaintextRejectionMarkers = [
        "The plain HTTP request was sent to HTTPS port",
        "Client sent an HTTP request to an HTTPS server"
    ]

    private static let summaryLimit = 300

    static func readable(_ body: String) -> String {
        let head = String(body.prefix(scanLimit))
        guard isHTML(head) else { return body }
        return title(in: head) ?? visibleText(in: head)
    }

    static func isPlaintextRejection(statusCode: Int, body: String) -> Bool {
        guard statusCode == 400 else { return false }
        let head = String(body.prefix(scanLimit))
        return plaintextRejectionMarkers.contains { head.range(of: $0, options: .caseInsensitive) != nil }
    }

    private static func isHTML(_ text: String) -> Bool {
        let start = text.drop { $0.isWhitespace }.prefix(20).lowercased()
        return start.hasPrefix("<html") || start.hasPrefix("<!doctype html")
    }

    private static func visibleText(in html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        let words = withoutTags.split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(summaryLimit))
    }

    private static func title(in html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let openEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: openEnd.upperBound..<html.endIndex)
        else { return nil }
        let words = html[openEnd.upperBound..<close.lowerBound].split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
