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
}
