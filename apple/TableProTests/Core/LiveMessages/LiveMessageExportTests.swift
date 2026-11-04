import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct LiveMessageExportTests {
    private static let kafka = LiveMessageEntry(id: 0, kind: .message(PluginLiveMessage(
        timestamp: Date(timeIntervalSince1970: 0),
        channel: "orders",
        payload: "a,\"b\"",
        key: "k1",
        partition: 2,
        offset: 41
    )))

    @Test("Each kind shows its own columns")
    func columnsPerKind() {
        #expect(LiveMessageExport.columns(for: .notifications) == [.time, .channel, .payload])
        #expect(LiveMessageExport.columns(for: .pubSub).contains(.pattern))
        #expect(LiveMessageExport.columns(for: .topics) == [.time, .channel, .partition, .offset, .key, .payload])
    }

    @Test("CSV quotes a field holding a comma or a quote")
    func csvQuotes() {
        let csv = LiveMessageExport.csv([Self.kafka], kind: .topics)
        let row = csv.components(separatedBy: "\r\n")[1]
        #expect(row.hasSuffix(",orders,2,41,k1,\"a,\"\"b\"\"\""))
    }

    // A quote a combining mark follows is one Character, so the field went out unquoted and split the row on import.
    @Test("CSV quotes and doubles a quote a combining mark follows")
    func csvQuotesThroughCombiningMarks() {
        let date = Date(timeIntervalSince1970: 0)
        let entry = LiveMessageEntry(id: 0, kind: .message(PluginLiveMessage(
            timestamp: date, channel: "orders", payload: "a\"\u{301},b"
        )))
        let row = LiveMessageExport.csv([entry], kind: .notifications).components(separatedBy: "\r\n")[1]
        let expected = LiveMessageExport.timeText(date) + ",orders,\"a\"\"\u{301},b\""
        #expect(Array(row.unicodeScalars) == Array(expected.unicodeScalars))
    }

    @Test("A CRLF in a value stays inside its TSV row")
    func tsvFlattensCarriageReturnLineFeed() {
        let entry = LiveMessageEntry(id: 0, kind: .message(PluginLiveMessage(
            timestamp: Date(timeIntervalSince1970: 0), channel: "orders", payload: "a\r\nb"
        )))
        let tsv = LiveMessageExport.tsv([entry], kind: .notifications)
        #expect(tsv.components(separatedBy: "\n").count == 2)
        #expect(tsv.hasSuffix("\ta  b"))
    }

    @Test("A gap row copies as Connection lost with its reason")
    func gapCopies() {
        let gap = LiveMessageEntry(id: 1, kind: .gap(reason: "timeout"))
        let tsv = LiveMessageExport.tsv([gap], kind: .notifications)
        #expect(tsv.components(separatedBy: "\n")[1] == "\t\(String(localized: "Connection lost"))\ttimeout")
    }

    @Test("Names split on commas and new lines, trimmed and without repeats")
    func startSheetNames() {
        #expect(LiveMessageStartSheet.names(in: " orders, audit log\norders,, ") == ["orders", "audit log"])
    }
}
