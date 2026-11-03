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

    @Test("A full buffer fed one message at a time keeps the newest in order across compactions")
    func oneAtATimePastTheCap() {
        var buffer = LiveMessageBuffer(capacity: 4)
        for index in 1...23 {
            buffer.append([Self.message("m\(index)")])
        }

        let ids = buffer.entries.map { $0.id }
        #expect(buffer.entries.compactMap { $0.message?.payload } == ["m20", "m21", "m22", "m23"])
        #expect(ids == [19, 20, 21, 22])
        #expect(buffer.droppedCount == 19)
    }

    @Test("Batches of every size wrap the buffer many times and it still holds exactly the newest, oldest first")
    func wrapsInOrder() {
        var buffer = LiveMessageBuffer(capacity: 5)
        var sent = 0
        for batch in [1, 2, 7, 5, 3, 11, 1, 4] + Array(repeating: 6, count: 160) {
            buffer.append((sent + 1...sent + batch).map { Self.message("m\($0)") })
            sent += batch
        }

        #expect(sent == 994)
        #expect(buffer.entries.count == buffer.capacity)
        #expect(buffer.entries.compactMap { $0.message?.payload } == (990...994).map { "m\($0)" })
        #expect(buffer.entries.map { $0.id } == Array(989...993))
        #expect(buffer.droppedCount == 989)
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
