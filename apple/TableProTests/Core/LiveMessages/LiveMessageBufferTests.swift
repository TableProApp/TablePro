import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct LiveMessageBufferTests {
    private static func message(_ payload: String, channel: String = "orders") -> PluginLiveMessage {
        PluginLiveMessage(timestamp: Date(timeIntervalSince1970: 0), channel: channel, payload: payload)
    }

    @Test("Keeps only the newest messages up to the cap and counts the ones it dropped")
    func keepsNewestUpToCap() {
        var buffer = LiveMessageBuffer(capacity: 3)
        buffer.append((1...5).map { Self.message("m\($0)") })

        #expect(buffer.entries.compactMap { $0.message?.payload } == ["m3", "m4", "m5"])
        #expect(buffer.droppedCount == 2)
    }

    @Test("Entry ids keep growing after a trim and a clear, so a table never reuses one")
    func idsNeverRepeat() {
        var buffer = LiveMessageBuffer(capacity: 2)
        buffer.append([Self.message("a"), Self.message("b"), Self.message("c")])
        let before = buffer.entries.map(\.id)
        buffer.clear()
        buffer.append([Self.message("d")])

        #expect(buffer.entries.isEmpty == false)
        #expect(!before.contains(buffer.entries[0].id))
    }

    @Test("A gap marker is kept in order and always passes the filter")
    func gapKeptAndUnfiltered() {
        var buffer = LiveMessageBuffer()
        buffer.append([Self.message("before")])
        buffer.appendGap(reason: "server closed the connection")
        buffer.append([Self.message("after", channel: "audit")])

        let visible = buffer.visible(filter: "audit")
        #expect(visible.count == 2)
        #expect(visible.first?.message == nil)
        #expect(visible.last?.message?.payload == "after")
    }

    @Test("The filter matches channel, payload and key, ignoring case")
    func filterMatchesFields() {
        var buffer = LiveMessageBuffer()
        buffer.append([
            Self.message("hello", channel: "orders"),
            PluginLiveMessage(timestamp: Date(), channel: "t", payload: "x", key: "Customer-7"),
            Self.message("other", channel: "misc"),
        ])

        #expect(buffer.visible(filter: "ORDERS").count == 1)
        #expect(buffer.visible(filter: "customer").count == 1)
        #expect(buffer.visible(filter: "  ").count == 3)
    }
}
