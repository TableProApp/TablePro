import Foundation
import TableProKafkaCore
import Testing

private struct WalkOutcome {
    let records: [Int64]
    let reads: [[Int64]]
    let start: Int64
}

// A partition log given by the offsets that hold a record, read the way the browse engine reads it.
private func walk(
    log: [Int64],
    end: Int64,
    floor: Int64,
    wanted: Int
) -> WalkOutcome {
    let firstStart = KafkaOffsetMath.stepBack(from: end, by: Int64(wanted), floor: floor)
    var tail = KafkaTailWalk<Int64>(wanted: wanted, end: end, firstStart: firstStart, floor: floor)
    var reads: [[Int64]] = []
    while let range = tail.nextRange {
        reads.append([range.start, range.end])
        tail.absorb(Array(log.filter { $0 >= range.start && $0 < range.end }.suffix(tail.needed)))
    }
    return WalkOutcome(records: tail.records, reads: reads, start: tail.start)
}

// What KafkaRecordOrdering.page takes from a tail window on one partition.
private func page(_ records: [Int64], skip: Int, limit: Int) -> [Int64] {
    Array(records.dropLast(skip).suffix(limit))
}

struct KafkaTailWalkTests {
    // One commit marker after every record: half the offsets hold no record.
    private static let markedLog = stride(from: Int64(0), to: 2_000, by: 2).map { $0 }

    @Test("A window with fewer records than offsets steps back until it holds the page")
    func stepsBackPastMarkers() {
        let outcome = walk(log: Self.markedLog, end: 2_000, floor: 0, wanted: 100)
        #expect(outcome.records == Array(stride(from: Int64(1_800), through: 1_998, by: 2)))
        #expect(outcome.reads == [[1_900, 2_000], [1_775, 1_900]])
        #expect(outcome.start == 1_775)
    }

    @Test("Page two follows page one with no record skipped or repeated")
    func pagesAreContiguous() {
        let first = page(walk(log: Self.markedLog, end: 2_000, floor: 0, wanted: 100).records, skip: 0, limit: 100)
        let second = page(walk(log: Self.markedLog, end: 2_000, floor: 0, wanted: 200).records, skip: 100, limit: 100)
        let third = page(walk(log: Self.markedLog, end: 2_000, floor: 0, wanted: 300).records, skip: 200, limit: 100)
        #expect(first == Array(stride(from: Int64(1_800), through: 1_998, by: 2)))
        #expect(second == Array(stride(from: Int64(1_600), through: 1_798, by: 2)))
        #expect(third == Array(stride(from: Int64(1_400), through: 1_598, by: 2)))
    }

    @Test("A deep page of a sparse log is not empty")
    func deepPageOfSparseLog() {
        let sparse = stride(from: Int64(0), to: 100_000, by: 10).map { $0 }
        let tenth = page(walk(log: sparse, end: 100_000, floor: 0, wanted: 1_000).records, skip: 900, limit: 100)
        #expect(tenth.count == 100)
        let expectedLast: Int64 = 99_990 - 900 * 10
        #expect(tenth.last == expectedLast)
    }

    @Test("The walk stops at the earliest offset with what the log holds")
    func stopsAtTheFloor() {
        let outcome = walk(log: [503, 507, 990], end: 1_000, floor: 500, wanted: 100)
        #expect(outcome.records == [503, 507, 990])
        #expect(outcome.start == 500)
        #expect(outcome.reads.last?.first == 500)
    }

    @Test("A window that already holds the page reads once")
    func denseWindowReadsOnce() {
        let dense = (0 ..< 1_000).map { Int64($0) }
        let outcome = walk(log: dense, end: 1_000, floor: 0, wanted: 50)
        #expect(outcome.reads == [[950, 1_000]])
        #expect(outcome.records == Array(950 ..< 1_000).map { Int64($0) })
    }

    @Test("A walk that finds nothing grows each step by the most it may")
    func emptyStretchGrowsFast() {
        let outcome = walk(log: [0], end: 10_000, floor: 0, wanted: 100)
        #expect(outcome.reads == [[9_900, 10_000], [9_500, 9_900], [7_900, 9_500], [1_500, 7_900], [0, 1_500]])
        #expect(outcome.records == [0])
    }

    @Test("An empty partition and an empty page read nothing past the end")
    func emptyCases() {
        let empty = walk(log: [], end: 40, floor: 40, wanted: 10)
        #expect(empty.reads == [[40, 40]])
        #expect(empty.records.isEmpty)

        var none = KafkaTailWalk<Int64>(wanted: 0, end: 10, firstStart: 0, floor: 0)
        let pending = none.nextRange != nil
        #expect(!pending)
        none.absorb([1])
        #expect(none.records.isEmpty)
    }

    @Test("The next width reaches as far as the last range's density says, and grows by the cap after an empty range")
    func nextWidth() {
        #expect(KafkaOffsetMath.nextWidth(lastWidth: 100, lastRecords: 50, needed: 50, maximumGrowth: 4) == 125)
        #expect(KafkaOffsetMath.nextWidth(lastWidth: 1_000, lastRecords: 1_000, needed: 1, maximumGrowth: 4) == 2)
        #expect(KafkaOffsetMath.nextWidth(lastWidth: 1_000, lastRecords: 100, needed: 900, maximumGrowth: 4) == 4_000)
        #expect(KafkaOffsetMath.nextWidth(lastWidth: 100, lastRecords: 0, needed: 10, maximumGrowth: 4) == 400)
        #expect(KafkaOffsetMath.nextWidth(lastWidth: .max, lastRecords: 0, needed: 1, maximumGrowth: 4) == .max)
    }

    @Test("An empty stretch below a dense range is crossed by growing steps, not a few offsets at a time")
    func denseThenEmpty() {
        let log = [Int64(0)] + (99_001 ..< 100_000).map { Int64($0) }
        let outcome = walk(log: log, end: 100_000, floor: 0, wanted: 1_000)
        #expect(outcome.reads.map { $0[1] - $0[0] } == [1_000, 2, 8, 32, 128, 512, 2_048, 8_192, 32_768, 55_310])
        #expect(outcome.records.count == 1_000)
        #expect(outcome.records.first == 0)
    }
}
