import Foundation

/// How a multi-partition read is presented as one list.
///
/// Split out from the browse engine because it is pure: it decides presentation order and
/// touches no connection, so it is the part that can be tested without a broker.
enum KafkaRecordOrdering {
    /// Orders a merged multi-partition read.
    ///
    /// Kafka guarantees order only within a partition, so any cross-partition ordering is a
    /// presentation choice rather than a property of the log. Timestamp first matches what a
    /// person reading a debug view expects; (partition, offset) breaks ties so the order is
    /// stable and paging cannot repeat or skip a record.
    static func merge(_ records: [KafkaRecord]) -> [KafkaRecord] {
        records.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.partition != rhs.partition { return lhs.partition < rhs.partition }
            return lhs.offset < rhs.offset
        }
    }

    /// The page to show, from the end of the merged run the scan was anchored to.
    ///
    /// A tail scan steps each of P partitions back by the page size and then reads forward, so
    /// the merged run holds up to P times the page and its newest records are at the END.
    /// Taking the front of it returns the oldest records of the tail window, which on one
    /// partition is the same rows and on three is the wrong end of the log. This is a separate
    /// function because that is a presentation decision with no I/O in it, and the defect
    /// survived because the code that made it could only be reached through a broker.
    static func page(_ ordered: [KafkaRecord], skip: Int, limit: Int, readsBackward: Bool) -> [KafkaRecord] {
        guard limit > 0 else { return [] }
        let dropped = max(0, skip)
        guard readsBackward else {
            return Array(ordered.dropFirst(dropped).prefix(limit))
        }
        return Array(ordered.dropLast(dropped).suffix(limit))
    }
}
