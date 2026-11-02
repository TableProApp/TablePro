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
