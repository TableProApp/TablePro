// Offsets come from the broker's replies, so arithmetic on them saturates or stops instead of trapping.
public enum KafkaOffsetMath {
    // Nothing follows Int64.max, so a read that reaches it is over.
    public static func offset(after offset: Int64) -> Int64? {
        offset < .max ? offset + 1 : nil
    }

    public static func messageCount(earliest: Int64, latest: Int64) -> Int64 {
        let (count, overflows) = latest.subtractingReportingOverflow(earliest)
        guard !overflows else { return latest < earliest ? 0 : .max }
        return max(0, count)
    }

    public static func total(_ counts: some Sequence<Int64>) -> Int64 {
        counts.reduce(0) { sum, count in
            let (next, overflows) = sum.addingReportingOverflow(count)
            return overflows ? (count < 0 ? .min : .max) : next
        }
    }

    // A start that falls below Int64 is below any floor there is.
    public static func stepBack(from end: Int64, by step: Int64, floor: Int64) -> Int64 {
        let (start, overflows) = end.subtractingReportingOverflow(step)
        return overflows ? floor : max(floor, start)
    }

    // A v2 batch header keeps the last offset it covers after compaction empties it or its records are aborted.
    public static func offset(afterBatchAt baseOffset: Int64, lastOffsetDelta: Int32) -> Int64? {
        let (last, overflows) = baseOffset.addingReportingOverflow(Int64(max(0, lastOffsetDelta)))
        return overflows ? nil : offset(after: last)
    }

    // As far back as the last range's density puts the missing records, a quarter more for an uneven spread, so a
    // sparse stretch is crossed in a few reads and a dense one is not read past the page. At most `maximumGrowth`
    // times the last range, which is also the step after a range that held nothing.
    public static func nextWidth(
        lastWidth: Int64,
        lastRecords: Int,
        needed: Int,
        maximumGrowth: Int64
    ) -> Int64 {
        let ceiling = max(1, lastWidth).multipliedReportingOverflow(by: max(2, maximumGrowth))
        let cap = ceiling.overflow ? Int64.max : ceiling.partialValue
        guard lastRecords > 0 else { return cap }
        let estimate = Double(max(0, needed)) * Double(max(1, lastWidth)) / Double(lastRecords) * 1.25
        guard estimate < Double(cap) else { return cap }
        return max(1, Int64(estimate.rounded(.up)))
    }
}

// Offsets are not one per record: transaction markers, aborted records and compaction leave offsets with no
// record, so a tail window is widened by the records it holds, not by the offsets it spans.
public struct KafkaTailWalk<Record> {
    public private(set) var records: [Record] = []
    // Nil once the walk holds `wanted` records or has read down to the floor.
    public private(set) var nextRange: (start: Int64, end: Int64)?
    public private(set) var start: Int64
    private let wanted: Int
    private let floor: Int64
    private let maximumGrowth: Int64

    public init(wanted: Int, end: Int64, firstStart: Int64, floor: Int64, maximumGrowth: Int64 = 4) {
        self.wanted = wanted
        self.floor = floor
        self.maximumGrowth = maximumGrowth
        start = firstStart
        nextRange = wanted > 0 ? (firstStart, end) : nil
    }

    // How many more records the walk takes; a read of `nextRange` keeps only its newest this many.
    public var needed: Int { max(0, wanted - records.count) }

    // `earlier` holds the newest records of `nextRange` in offset order, all older than the ones already held.
    public mutating func absorb(_ earlier: [Record]) {
        guard let range = nextRange else { return }
        start = range.start
        records = Array((earlier + records).suffix(wanted))
        guard records.count < wanted, range.start > floor else {
            nextRange = nil
            return
        }
        let (span, overflows) = range.end.subtractingReportingOverflow(range.start)
        let width = KafkaOffsetMath.nextWidth(
            lastWidth: overflows ? Int64.max : span,
            lastRecords: earlier.count,
            needed: needed,
            maximumGrowth: maximumGrowth
        )
        nextRange = (KafkaOffsetMath.stepBack(from: range.start, by: width, floor: floor), range.start)
    }
}
