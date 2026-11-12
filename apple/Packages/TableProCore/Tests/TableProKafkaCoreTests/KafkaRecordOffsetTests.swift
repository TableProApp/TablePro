import Foundation
import TableProKafkaCore
import TableProWireIO
import Testing

private func decodeOne(baseOffset: Int64, baseTimestamp: Int64, offsetDelta: Int32, timestampDelta: Int64 = 0) throws -> [KafkaRecord] {
    let blob = KafkaBatchFixture.batch(
        baseOffset: baseOffset,
        baseTimestamp: baseTimestamp,
        payload: KafkaBatchFixture.record(offsetDelta: offsetDelta, timestampDelta: timestampDelta, value: Data("hi".utf8))
    )
    var budget = DecompressionBudget.standard
    return try KafkaRecordBatchDecoder.decode(blob: blob, partition: 0, skipAborted: true, budget: &budget).records
}

@Test func decodesAnOrdinaryBatchAtItsOffset() throws {
    let records = try decodeOne(baseOffset: 41, baseTimestamp: 1_700_000_000_000, offsetDelta: 1)
    #expect(records.map { $0.offset } == [42])
    #expect(records.map { $0.timestamp } == [1_700_000_000_000])
    #expect(records.first?.value == Data("hi".utf8))
}

@Test func offsetPastInt64IsAMalformedReplyNotACrash() {
    let error = #expect(throws: KafkaError.self) {
        try decodeOne(baseOffset: .max, baseTimestamp: 1_700_000_000_000, offsetDelta: 1)
    }
    guard case .malformedResponse? = error else {
        Issue.record("expected a malformed reply, got \(String(describing: error))")
        return
    }
}

@Test func recordAtTheLastOffsetDecodesAndEndsPaging() throws {
    let records = try decodeOne(baseOffset: .max, baseTimestamp: 1_700_000_000_000, offsetDelta: 0)
    #expect(records.map { $0.offset } == [.max])
    #expect(KafkaOffsetMath.offset(after: .max) == nil)
    #expect(KafkaOffsetMath.offset(after: 41) == 42)
}

@Test func timestampPastInt64WrapsLikeKafkasClient() throws {
    let records = try decodeOne(baseOffset: 0, baseTimestamp: .max, offsetDelta: 0, timestampDelta: 1)
    #expect(records.map { $0.timestamp } == [.min])
}

@Test func messageCountSaturatesOnBrokerOffsets() {
    #expect(KafkaOffsetMath.messageCount(earliest: 3, latest: 10) == 7)
    #expect(KafkaOffsetMath.messageCount(earliest: 10, latest: 3) == 0)
    #expect(KafkaOffsetMath.messageCount(earliest: .min, latest: .max) == .max)
    #expect(KafkaOffsetMath.messageCount(earliest: .max, latest: .min) == 0)
}

@Test func topicTotalSaturates() {
    #expect(KafkaOffsetMath.total([4, 5]) == 9)
    #expect(KafkaOffsetMath.total([.max, 1, 1]) == .max)
}

@Test func tailWindowStepsBackWithoutLeavingInt64() {
    #expect(KafkaOffsetMath.stepBack(from: 1_000, by: 100, floor: 0) == 900)
    #expect(KafkaOffsetMath.stepBack(from: 50, by: 100, floor: 0) == 0)
    #expect(KafkaOffsetMath.stepBack(from: .min + 1, by: 100, floor: -5) == -5)
    #expect(KafkaOffsetMath.stepBack(from: .min + 1, by: 100, floor: .min) == .min)
}

@Test func abortedRunSkipsOnlyItsOwnProducerUntilItsMarker() throws {
    let aborted = KafkaAbortedTransaction(producerId: 7, firstOffset: 5)
    func batch(_ producerId: Int64, at offset: Int64, flags: Int16 = KafkaBatchFixture.transactional) -> Data {
        KafkaBatchFixture.batch(
            baseOffset: offset,
            flags: flags,
            producerId: producerId,
            payload: KafkaBatchFixture.record(value: Data("\(producerId)@\(offset)".utf8))
        )
    }
    let blob = batch(7, at: 4)
        + batch(7, at: 10)
        + batch(8, at: 11)
        + batch(7, at: 12, flags: KafkaBatchFixture.transactional | KafkaBatchFixture.control)
        + batch(7, at: 13, flags: 0)
    var budget = DecompressionBudget.standard
    let decoded = try KafkaRecordBatchDecoder.decode(
        blob: blob,
        partition: 0,
        abortedTransactions: [KafkaAbortedTransaction(producerId: 7, firstOffset: 40), aborted],
        skipAborted: true,
        budget: &budget
    )
    #expect(decoded.records.map { $0.offset } == [4, 11, 13])
    #expect(decoded.nextOffset == 14)
}

@Test func offsetAfterABatchComesFromItsHeader() {
    #expect(KafkaOffsetMath.offset(afterBatchAt: 100, lastOffsetDelta: 4) == 105)
    #expect(KafkaOffsetMath.offset(afterBatchAt: 100, lastOffsetDelta: 0) == 101)
    #expect(KafkaOffsetMath.offset(afterBatchAt: 100, lastOffsetDelta: -1) == 101)
    #expect(KafkaOffsetMath.offset(afterBatchAt: .max, lastOffsetDelta: 0) == nil)
    #expect(KafkaOffsetMath.offset(afterBatchAt: .max - 1, lastOffsetDelta: 2) == nil)
}

private func decodeBlob(_ blob: Data) throws -> (records: [KafkaRecord], truncated: Bool, nextOffset: Int64?) {
    var budget = DecompressionBudget.standard
    return try KafkaRecordBatchDecoder.decode(blob: blob, partition: 0, skipAborted: true, budget: &budget)
}

private func marker(at offset: Int64, producerId: Int64 = 7) -> Data {
    KafkaBatchFixture.batch(
        baseOffset: offset,
        flags: KafkaBatchFixture.transactional | KafkaBatchFixture.control,
        producerId: producerId,
        payload: KafkaBatchFixture.record(value: nil)
    )
}

@Test func aReplyOfOnlyACommitMarkerStillMovesTheReadOn() throws {
    let decoded = try decodeBlob(marker(at: 41))
    #expect(decoded.records.isEmpty)
    #expect(decoded.nextOffset == 42)
}

@Test func aTrailingMarkerMovesTheReadPastIt() throws {
    let blob = KafkaBatchFixture.batch(
        baseOffset: 40, flags: KafkaBatchFixture.transactional, producerId: 7,
        payload: KafkaBatchFixture.record(value: Data("row".utf8))
    ) + marker(at: 41)
    let decoded = try decodeBlob(blob)
    #expect(decoded.records.map { $0.offset } == [40])
    #expect(decoded.nextOffset == 42)
}

@Test func anAbortedRunMovesTheReadPastIt() throws {
    let blob = KafkaBatchFixture.batch(
        baseOffset: 10, flags: KafkaBatchFixture.transactional, producerId: 7, recordCount: 3,
        payload: KafkaBatchFixture.record(offsetDelta: 0, value: Data("a".utf8))
            + KafkaBatchFixture.record(offsetDelta: 1, value: Data("b".utf8))
            + KafkaBatchFixture.record(offsetDelta: 2, value: Data("c".utf8))
    ) + marker(at: 13)
    var budget = DecompressionBudget.standard
    let decoded = try KafkaRecordBatchDecoder.decode(
        blob: blob,
        partition: 0,
        abortedTransactions: [KafkaAbortedTransaction(producerId: 7, firstOffset: 10)],
        skipAborted: true,
        budget: &budget
    )
    #expect(decoded.records.isEmpty)
    #expect(decoded.nextOffset == 14)
}

// Compaction keeps an emptied batch's header, last offset included (Kafka protocol docs, Record Batch).
@Test func aBatchCompactionEmptiedMovesTheReadPastItsWholeRange() throws {
    let decoded = try decodeBlob(KafkaBatchFixture.batch(baseOffset: 200, recordCount: 5, payload: Data()))
    #expect(decoded.records.isEmpty)
    #expect(decoded.nextOffset == 205)
}

@Test func onlyWholeBatchesMoveTheReadOn() throws {
    let whole = KafkaBatchFixture.batch(baseOffset: 7, payload: KafkaBatchFixture.record(value: Data("x".utf8)))
    let cut = try decodeBlob(whole + whole.prefix(20))
    #expect(cut.records.map { $0.offset } == [7])
    #expect(cut.truncated)
    #expect(cut.nextOffset == 8)

    let nothingWhole = try decodeBlob(whole.prefix(whole.count - 1))
    #expect(nothingWhole.records.isEmpty)
    #expect(nothingWhole.nextOffset == nil)
}
