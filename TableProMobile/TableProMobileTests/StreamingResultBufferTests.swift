import Foundation
import Testing
import TableProModels
@testable import TableProMobile

@MainActor
@Suite("StreamingResultBuffer")
struct StreamingResultBufferTests {

    @Test("flush appends pending rows and apply records columns")
    func flushAppends() {
        let buffer = StreamingResultBuffer(capacity: 100)
        buffer.apply(.columns([ColumnInfo(name: "id", typeName: "INT", ordinalPosition: 0)]))
        buffer.apply(.row(Row(cells: [.text("1")])))
        buffer.apply(.row(Row(cells: [.text("2")])))
        buffer.flush()

        #expect(buffer.legacyRows.count == 2)
        #expect(buffer.window.count == 2)
        #expect(buffer.columns.count == 1)
        #expect(buffer.legacyRows.first?.first == "1")
    }

    @Test("shrink keeps window and legacy rows in lockstep")
    func shrinkLockstep() {
        let buffer = StreamingResultBuffer(capacity: 100)
        for index in 0..<10 {
            buffer.apply(.row(Row(cells: [.text("\(index)")])))
        }
        buffer.flush()
        #expect(buffer.legacyRows.count == 10)

        buffer.shrink(to: 4)

        #expect(buffer.legacyRows.count == 4)
        #expect(buffer.window.count == 4)
    }

    @Test("reset clears all state")
    func resetClears() {
        let buffer = StreamingResultBuffer(capacity: 100)
        buffer.apply(.columns([ColumnInfo(name: "id", typeName: "INT", ordinalPosition: 0)]))
        buffer.apply(.row(Row(cells: [.text("1")])))
        buffer.flush()
        buffer.markTruncated(.memoryPressure)

        buffer.reset()

        #expect(buffer.isEmpty)
        #expect(buffer.columns.isEmpty)
        #expect(buffer.truncation == nil)
    }
}
