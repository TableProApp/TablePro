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
}
